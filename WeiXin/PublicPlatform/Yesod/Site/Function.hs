{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
module WeiXin.PublicPlatform.Yesod.Site.Function
    ( module WeiXin.PublicPlatform.Yesod.Site.Function
    , module WeiXin.PublicPlatform.Yesod.Site.Data
    )where

import ClassyPrelude
import Yesod
import Control.Lens
import Network.Wreq
import Control.Monad.Trans.Except
import Control.Monad.Trans.Maybe
import qualified Data.Text.Lazy             as LT
import qualified Data.ByteString.Lazy       as LB
import qualified Data.Conduit.List          as CL
import qualified Data.Map.Strict            as Map
import Data.Conduit
import Database.Persist.Sql
import Data.Time                            (addUTCTime, diffUTCTime, NominalDiffTime)

import Yesod.Helpers.Persist

import WeiXin.PublicPlatform.Security
import WeiXin.PublicPlatform.Media
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.EndUser
import WeiXin.PublicPlatform.InMsgHandler
import WeiXin.PublicPlatform.Yesod.Site.Data
import WeiXin.PublicPlatform.Yesod.Model



-- | Handler: 保存所有收到的比较原始的消息（解密之后的结果）到数据库
data StoreInMsgToDB m = StoreInMsgToDB
                            WxppAppID
                            WxppDbRunner
                                -- function to run DB actions
                            (Bool -> WxppInMsgRecordId -> WxppBriefMediaID -> m ())
                                -- function to download media file
                                -- 推荐使用异步方式下载

type instance WxppInMsgProcessResult (StoreInMsgToDB m) = WxppInMsgHandlerResult

instance JsonConfigable (StoreInMsgToDB m) where
    type JsonConfigableUnconfigData (StoreInMsgToDB m) =
            ( WxppAppID
            , WxppDbRunner
            , Bool -> WxppInMsgRecordId -> WxppBriefMediaID -> m ()
            )

    isNameOfInMsgHandler _ = ( == "db-store-all" )

    parseWithExtraData _ (x,y,z) _obj = return $ StoreInMsgToDB x y z


instance (MonadIO m, MonadLogger m
    , MonadBaseControl IO m
    , MonadThrow m
    ) => IsWxppInMsgProcessor m (StoreInMsgToDB m) where

    processInMsg (StoreInMsgToDB {}) _cache _bs _m_ime = do
        $logWarnS wxppLogSource $
            "StoreInMsgToDB now do nothing when used as incoming message handler"
        return $ Right []


instance (MonadIO m, MonadLogger m
    , MonadBaseControl IO m
    , MonadThrow m
    ) => IsWxppInMsgProcMiddleware m (StoreInMsgToDB m) where
    preProcInMsg (StoreInMsgToDB app_id db_runner media_downloader) _cache bs m_ime = runMaybeT $ do
        now <- liftIO getCurrentTime
        (msg_record_id, (is_video, mids)) <- mapMaybeT (runWxppDB db_runner) $ do
            let m_to        = fmap wxppInToUserName m_ime
                m_from      = fmap wxppInFromUserName m_ime
                m_ctime     = fmap wxppInCreatedTime m_ime
                m_msg_id    = join $ fmap wxppInMessageID m_ime
            old_or_msg_record_id <- lift $ insertBy $ WxppInMsgRecord
                            app_id
                            m_to m_from m_ctime m_msg_id
                            (LB.toStrict bs)
                            now

            msg_record_id <- case old_or_msg_record_id of
                Left (Entity old_id _) -> do
                    $logWarnS wxppLogSource $
                        "got a duplicate message from WeiXin platform: db id=" <> toPathPiece old_id
                            <>", MsgId=" <> (fromString $ show $ fmap unWxppInMsgID m_msg_id)
                    mzero

                Right x -> return x

            -- save any temporary media data
            (is_video, mids) <- liftM (fromMaybe (False, [])) $ forM m_ime $ \ime -> do
                        case wxppInMessage ime of
                            WxppInMsgImage mid _   -> return (False, [mid])
                            WxppInMsgVoice mid _ _ -> return (False, [mid])
                            WxppInMsgVideo mid mid2 -> return (True, [mid, mid2])
                            _                       -> return (False, [])
            return (msg_record_id, (is_video, mids))

        lift $ forM_ mids $ \mid -> do
            media_downloader (not is_video) msg_record_id mid
        return (bs, m_ime)


-- | Handler: 更新 WxppOpenIdUnionId 的记录
data CacheAppOpenIdToUnionId = CacheAppOpenIdToUnionId
                                    WxppAppID
                                    WxppDbRunner
                                        -- ^ function to run DB actions

type instance WxppInMsgProcessResult CacheAppOpenIdToUnionId = WxppInMsgHandlerResult

instance JsonConfigable CacheAppOpenIdToUnionId where
    type JsonConfigableUnconfigData CacheAppOpenIdToUnionId =
            ( WxppAppID
            , WxppDbRunner
            )

    isNameOfInMsgHandler _ = ( == "update-openid-to-unionid" )

    parseWithExtraData _ (x, y) _obj = return $ CacheAppOpenIdToUnionId x y


instance (MonadIO m
    , MonadCatch m
    , MonadLogger m
    , Functor m
    , MonadBaseControl IO m
    ) => IsWxppInMsgProcessor m CacheAppOpenIdToUnionId where

    processInMsg (CacheAppOpenIdToUnionId {}) _cache _bs _m_ime = runExceptT $ do
        $logWarnS wxppLogSource $
            "CacheAppOpenIdToUnionId now do nothing when used as incoming message handler"
        return []


instance (MonadIO m
    , MonadCatch m
    , MonadLogger m
    , Functor m
    , MonadBaseControl IO m
    ) => IsWxppInMsgProcMiddleware m CacheAppOpenIdToUnionId where

    preProcInMsg (CacheAppOpenIdToUnionId app_id db_runner) cache bs m_ime = do
        forM_ m_ime $ \ime -> do
            let m_subs_or_unsubs = case wxppInMessage ime of
                            (WxppInMsgEvent WxppEvtSubscribe)               -> Just True
                            (WxppInMsgEvent (WxppEvtSubscribeAtScene {}))   -> Just True
                            (WxppInMsgEvent WxppEvtUnsubscribe)             -> Just False
                            _                                               -> Nothing

            case m_subs_or_unsubs of
                Just True -> void $ runExceptT $ do
                    atk <- (tryWxppWsResultE "getting access token" $ liftIO $
                                wxppCacheGetAccessToken cache app_id)
                            >>= maybe (throwE $ "no access token available") (return . fst)
                    let open_id = wxppInFromUserName ime
                    qres <- tryWxppWsResultE "wxppQueryEndUserInfo" $
                                wxppQueryEndUserInfo atk open_id

                    let m_uid = endUserQueryResultUnionID qres
                    now <- liftIO getCurrentTime

                    lift $ runWxppDB db_runner $ do
                        void $ insertOrUpdate
                            (WxppUserCachedInfo app_id open_id m_uid now)
                            [ WxppUserCachedInfoUnionId =. m_uid
                            , WxppUserCachedInfoUpdatedTime =. now
                            ]

                Just False -> do
                    -- 取消关注时，目前先不删除记录
                    -- 估计 openid unionid 对于固定的用户是固定的
                    return ()

                _ -> return ()

        return $ Just (bs, m_ime)


type TrackHandledInMsgInnerMap = Map (WxppAppID, WxppInMsgAmostUniqueID)
                                  (UTCTime, Maybe (Either String UTCTime))

-- | 检查收到的信息有没有处理过，如果是，则不再处理
data TrackHandledInMsg = TrackHandledInMsg
                            NominalDiffTime
                            WxppAppID
                            (MVar TrackHandledInMsgInnerMap)

instance JsonConfigable TrackHandledInMsg where
  type JsonConfigableUnconfigData TrackHandledInMsg =
    ( NominalDiffTime
    , WxppAppID
    , MVar TrackHandledInMsgInnerMap
    )

  isNameOfInMsgHandler _ t = t == "track-handled-in-msg"

  parseWithExtraData _ (x1, x2, x3) _ = return $ TrackHandledInMsg x1 x2 x3


instance (MonadIO m
    , MonadCatch m
    , MonadLogger m
    , Functor m
    , MonadBaseControl IO m
    ) => IsWxppInMsgProcMiddleware m TrackHandledInMsg where

    preProcInMsg (TrackHandledInMsg _ app_id map_mar) _cache bs m_ime = do
      case almostUniqueIdOfWxppInMsgEntity <$> m_ime of
        Nothing -> do
          $logWarnS wxppLogSource $
            "could not parse incoming or no message id, message was:\n"
            <> LT.toStrict (decodeUtf8 bs)
          return $ Just (bs, m_ime)

        Just msg_id -> do
          now <- liftIO getCurrentTime
          m_prev_rec <- liftIO $ modifyMVar map_mar $
                    \the_map -> do
                      let k = (app_id, msg_id)
                          v = (now, Nothing)
                      return $!
                        case Map.lookup k the_map of
                          Nothing     -> (Map.insert k v the_map, Nothing)
                          Just old_v  -> (the_map, Just old_v)

          case m_prev_rec of
            Nothing -> do
              -- 正常的情况
              return $ Just (bs, m_ime)

            Just (_prev_start, m_prev_done) -> do
              case m_prev_done of
                Nothing -> do
                  $logWarnS wxppLogSource $
                    "Duplicate incoming message before previous one could be handled successfully:"
                    <> tshow msg_id
                  return Nothing

                Just (Left _) -> do
                  -- handled before, but failed
                  $logInfoS wxppLogSource $
                    "Duplicate incoming message with previous one was handled unsuccessfully:"
                    <> tshow msg_id
                  -- retry
                  return $ Just (bs, m_ime)

                Just (Right _) -> do
                  -- handled before, and success
                  $logInfoS wxppLogSource $
                    "Duplicate incoming message with previous one was handled successfully:"
                    <> tshow msg_id
                  return Nothing

    postProcInMsg (TrackHandledInMsg slow_threshold app_id map_mar) _bs m_ime res = do
      trackHandleInMsgSaveResult slow_threshold app_id map_mar m_ime Nothing
      return res

    onProcInMsgError (TrackHandledInMsg slow_threshold app_id map_mar) _bs m_ime err = do
      trackHandleInMsgSaveResult slow_threshold app_id map_mar m_ime (Just err)

trackHandleInMsgSaveResult :: (MonadIO m, MonadLogger m)
                            => NominalDiffTime
                            -> WxppAppID
                            -> MVar TrackHandledInMsgInnerMap
                            -> Maybe WxppInMsgEntity
                            -> Maybe String
                            -> m ()
trackHandleInMsgSaveResult slow_threshold app_id map_mvar m_ime m_err = do
  case almostUniqueIdOfWxppInMsgEntity <$> m_ime of
    Nothing -> return ()
    Just msg_id -> do
      now <- liftIO getCurrentTime
      let dt = addUTCTime (negate $ fromIntegral (1800 :: Int)) now
      m_val <- liftIO $ modifyMVar map_mvar $
                \the_map -> do
                  let (m_val, new_map) = Map.updateLookupWithKey
                                          (\_ -> Just . second
                                                      (const $ Just $ maybe (Right now) Left m_err)
                                          )
                                          (app_id, msg_id)
                                          the_map
                      -- remove histories that are long ago
                      new_map' = Map.filter ((< dt) . fst) new_map
                  
                  return $! (new_map', m_val)

      case m_val of
        Nothing -> do
          $logErrorS wxppLogSource $
            "Previous handling info was not found: " <> tshow msg_id

        Just (start_time, _) -> do
          let time_used = diffUTCTime now start_time
          when (time_used > slow_threshold) $ do
            $logWarnS wxppLogSource $
              "Too slow to handle message " <> tshow msg_id
              <> ", time used: "
              <> tshow (realToFrac time_used :: Float) <> " seconds."

-- | 下载多媒体文件，保存至数据库
downloadSaveMediaToDB ::
    ( MonadLogger m
    , MonadCatch m
    , MonadIO m
#if MIN_VERSION_persistent(2, 0, 0)
    , PersistUnique backend
    , backend ~ PersistEntityBackend WxppStoredMedia
#else
    , PersistUnique m
    , PersistMonadBackend m ~ PersistEntityBackend WxppStoredMedia
#endif
    ) =>
    Bool
    -> AccessToken
    -> WxppInMsgRecordId
    -> WxppBriefMediaID
#if MIN_VERSION_persistent(2, 0, 0)
    -> ReaderT backend m ()
#else
    -> m ()
#endif
downloadSaveMediaToDB if_ssl atk msg_id media_id = do
    err_or_rb <- tryWxppWsResult $ wxppDownloadMedia if_ssl atk media_id
    case err_or_rb of
        Left err -> do
                    $(logErrorS) wxppLogSource $ "Failed to download media '" <> unWxppBriefMediaID media_id
                                    <> "': " <> (fromString $ show err)
        Right rb -> do
                    now <- liftIO getCurrentTime
                    old_or_id <- insertBy $ WxppStoredMedia
                                                (accessTokenApp atk)
                                                media_id
                                                msg_id
                                                (LB.toStrict $ rb ^. responseBody)
                                                (rb ^. responseHeader "Content-Type")
                                                now
                    case old_or_id of
                        Left (Entity old_id _) -> do
                            $(logWarnS) wxppLogSource $ "Media '" <> unWxppBriefMediaID media_id
                                            <> "' already in DB, record id: "
                                            <> toPathPiece old_id
                        Right _ -> return ()



-- | 找出最近一段时间内有消息发給系统的用户
wxppUserLatestActiveTime :: (MonadIO m, MonadResource m) =>
    UTCTime         -- ^ 只检查过去一段时间内的消息历史
    -> WxppAppID
    -> Source (ReaderT WxppDbBackend m) (WxppOpenID, UTCTime)
wxppUserLatestActiveTime start_time app_id = do
    open_id_fn <- lift $ getFieldName WxppInMsgRecordFrom
    created_time_fn <- lift $ getFieldName WxppInMsgRecordCreatedTime
    app_fn <- lift $ getFieldName WxppInMsgRecordApp
    table_name <- lift $ getTableName (error "WxppInMsgRecord forced" :: WxppInMsgRecord)
    let query = "SELECT "
                    <> open_id_fn
                    <> ",MAX(" <> created_time_fn <> ")"
                    <> " FROM "
                    <> table_name
                    <> " WHERE "
                    <> app_fn <> "= ?"
                    <> " AND "
                    <> created_time_fn <> ">= ?"
                    <> " GROUP BY " <> open_id_fn
    rawQuery query [ toPersistValue app_id, toPersistValue start_time]
        $= CL.mapM (\x -> case x of
                        [v1, v2]    -> return $
                                            (,) <$> fromPersistValue v1
                                                <*> fromPersistValue v2

                        _       -> throwM $ PersistMarshalError $
                                            "Expecting 2 columns, but got "
                                                <> (fromString $ show $ length x)
                    )
        =$= CL.mapM (either (throwM . PersistMarshalError) return)
