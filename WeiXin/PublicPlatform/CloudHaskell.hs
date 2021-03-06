module WeiXin.PublicPlatform.CloudHaskell where

import           ClassyPrelude                                      hiding
                                                                     (newChan)
import           Control.Distributed.Process
import           Control.Distributed.Process.Async
import           Control.Distributed.Process.MonadBaseControl       ()
import           Control.Distributed.Process.Node                   hiding (newLocalNode)
import           Control.Monad.Except                               (runExceptT,
                                                                     throwError)
import           Control.Monad.Logger
import           Control.Monad.Trans.Control                        (MonadBaseControl)
import           Data.Aeson
import           Data.Binary                                        (Binary (..))
import qualified Data.ByteString.Lazy                               as LB
import           System.Timeout                                     (timeout)

import           WeiXin.PublicPlatform.InMsgHandler
import           WeiXin.PublicPlatform.Class

-- | 代表一种能找到接收 w 信息的 Process/SendPort 信息
data CloudBackendInfo w = CloudBackendInfo
  { cloudBackendCreateLocalNode :: IO LocalNode    -- ^ create new LocalNode
  , cloudBackendSendPortProcess :: IO [SendPort w] -- ^ 与这些 Process 通讯来处理真正的业务逻辑
  }

-- | A middleware to send event notifications of some types to the cloud (async)
data TeeEventToCloud = TeeEventToCloud
                          (CloudBackendInfo WrapInMsgHandlerInput)
                          [Text]
                            -- ^ event names to forward (wxppEventTypeString)
                            -- if null, forward all.

instance JsonConfigable TeeEventToCloud where
    type JsonConfigableUnconfigData TeeEventToCloud = CloudBackendInfo WrapInMsgHandlerInput

    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler _ = (== "tee-to-cloud")

    parseWithExtraData _ x o = TeeEventToCloud x
                                        <$> o .: "event-types"

instance (MonadIO m, MonadCatch m, MonadLogger m) => IsWxppInMsgProcMiddleware m TeeEventToCloud where
    preProcInMsg
      (TeeEventToCloud (CloudBackendInfo new_local_node get_ports) evt_types)
      _cache app_info bs ime = do
          case wxppInMessage ime of
            WxppInMsgEvent evt -> do
              when (null evt_types || wxppEventTypeString evt `elem` evt_types) $ do
                send_port_list <- liftIO get_ports
                if null send_port_list
                   then do
                     $logWarnS wxppLogSource $ "No SendPort available to send event notifications"
                   else do
                     {-
                     m_union_id <- runMaybeT $ do
                       atk <- fmap fst $ MaybeT $ liftIO $ wxppCacheGetAccessToken cache app_id
                       MaybeT $ wxppCachedGetEndUserUnionID cache
                                     (fromIntegral (maxBound :: Int)) -- because union id is stable
                                     atk
                                     (wxppInFromUserName ime)
                      --}
                     let m_union_id = Nothing
                     let msg = WrapInMsgHandlerInput app_id bs ime m_union_id

                     node <- liftIO new_local_node
                     liftIO $ runProcess node $ do
                       forM_ send_port_list $ \sp -> do
                         sendChan sp msg

            _ -> return ()

          return $ Just (bs, ime)
          where
            app_id = procAppIdInfoReceiverId app_info


-- | A message handler that send WxppInMsgEntity to peers and wait for responses
data DelegateInMsgToCloud (m :: * -> *) =
                          DelegateInMsgToCloud
                              (CloudBackendInfo (WrapInMsgHandlerInput, SendPort WxppInMsgHandlerResult))
                              Int
                                -- ^ timeout (ms) when selecting processes to handle
                                -- 配置时用的单位是秒，浮点数

instance JsonConfigable (DelegateInMsgToCloud m) where
    type JsonConfigableUnconfigData (DelegateInMsgToCloud m) =
            CloudBackendInfo (WrapInMsgHandlerInput, SendPort WxppInMsgHandlerResult)

    -- | 假定每个算法的配置段都有一个 name 的字段
    -- 根据这个方法选择出一个指定算法类型，
    -- 然后从 json 数据中反解出相应的值
    isNameOfInMsgHandler _ = (== "deletgate-to-cloud")

    -- | timeout number is a float in seconds
    parseWithExtraData _ x1 o = DelegateInMsgToCloud x1
                                  <$> (fmap (round . (* 1000000)) $
                                          o .:? "timeout" .!= (3 :: Float)
                                          -- 选择 3 秒超时是因为微信5秒超时
                                          -- 加上网络通讯等其它一些开销
                                      )

type instance WxppInMsgProcessResult (DelegateInMsgToCloud m) = WxppInMsgHandlerResult

instance (MonadIO m, MonadLogger m, MonadBaseControl IO m, MonadCatch m)
  => IsWxppInMsgProcessor m (DelegateInMsgToCloud m) where
    processInMsg
      (DelegateInMsgToCloud (CloudBackendInfo new_local_node get_ports) t1)
      _cache app_info bs ime = runExceptT $ do
            send_port_list <- liftIO get_ports
            when (null send_port_list) $ do
              let msg = "No SendPort available in cloud haskell"
              $logErrorS wxppLogSource $ fromString msg
              throwError msg

            {-
             - It's a little slow to call WeiXin API, so let cloud handler do it itself.
            let get_atk = (tryWxppWsResultE "getting access token" $ liftIO $
                                wxppCacheGetAccessToken cache app_id)
                            >>= maybe (throwError $ "no access token available") (return . fst)

            atk <- get_atk
            m_union_id <- wxppCachedGetEndUserUnionID cache
                             (fromIntegral (maxBound :: Int)) -- because union id is stable
                             atk
                             (wxppInFromUserName ime)
             --}
            let m_union_id = Nothing

            let cloud_pack_msg = WrapInMsgHandlerInput app_id bs ime m_union_id

            let send_recv sp = do
                  (send_port, recv_port) <- newChan
                  sendChan sp (cloud_pack_msg, send_port)
                  receiveChanTimeout t1 recv_port

            let get_answer = do
                  node <- liftIO new_local_node
                  Just async_res_list <- liftIO $ runProcessTimeout maxBound node $ do
                                      async_list <- forM send_port_list $ \sp -> do
                                                      fmap (sp,) $
                                                        asyncLinked $ AsyncTask $ send_recv sp

                                      forM async_list $ \(sp, ayp) -> fmap (sp,) $ wait ayp

                  res_list <- forM async_res_list $ \(sp, async_res) -> do
                                case async_res of
                                  AsyncDone mx -> do
                                    when (isNothing mx) $ do
                                        $logWarnS wxppLogSource $
                                          "Cloud SendPort at "
                                          <> tshow (sendPortId sp)
                                          <> " timed-out."
                                    return mx

                                  AsyncPending -> do
                                    $logErrorS wxppLogSource $
                                      "AsyncResult should never be AsyncPending"
                                    return Nothing

                                  r -> do
                                    $logErrorS wxppLogSource $
                                        "error when handling msg with cloud: "
                                        <> tshow r
                                    return Nothing

                  return $ join $ catMaybes res_list

            let handle_err err = do
                  let msg = "got exception when running cloud-haskell code: "
                              <> show err
                  $logErrorS wxppLogSource $ fromString msg
                  throwError msg

            get_answer `catchAny` handle_err

          where
            app_id = procAppIdInfoReceiverId app_info


-- | Cloud message that wraps incoming message info
data WrapInMsgHandlerInput = WrapInMsgHandlerInput
                                WxppAppID
                                LB.ByteString
                                WxppInMsgEntity
                                (Maybe WxppUnionID)
                                  -- ^ 用户的 union id
                                  -- 增加这个额外信息有两个目的
                                  -- * 因为大多数情况下,union id都有用,
                                  --   所以如果发送者能提供,可以简化接收者的许多重复代码
                                  -- * 方便模拟测试.
                            deriving (Typeable, Generic)
instance Binary WrapInMsgHandlerInput



runProcessTimeout :: Int -> LocalNode -> Process a -> IO (Maybe a)
runProcessTimeout t node proc = do
  mv <- newEmptyMVar

  pid_mvar <- newEmptyMVar
  runProcess node $ do
    getSelfPid >>= putMVar pid_mvar
    r <- proc
    putMVar mv r

  pid <- readMVar pid_mvar
  mx <- timeout t $ readMVar mv
  when (isNothing mx) $ do
    runProcess node $ exit pid (asString "timed-out")

  return mx
