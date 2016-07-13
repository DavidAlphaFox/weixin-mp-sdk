{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.ThirdParty
  ( module WeiXin.PublicPlatform.Types
  , module WeiXin.PublicPlatform.ThirdParty
  ) where

import           ClassyPrelude
import           Control.DeepSeq       (NFData)
import           Control.Lens          hiding ((.=))
import           Control.Monad.Reader  (asks)
import           Data.Aeson            as A
import           Data.Aeson.Types      as A
import           Data.Proxy            (Proxy (..))
import           Data.Time             (NominalDiffTime)
import           Database.Persist.Sql  (PersistField (..), PersistFieldSql (..))
import           Network.Wreq          hiding (Proxy)
import qualified Network.Wreq.Session  as WS
import           Text.Blaze.Html       (ToMarkup (..))
import           Text.Shakespeare.I18N (ToMessage (..))
import           Text.XML.Cursor

import           Yesod.Helpers.Utils   (queryTextSetParam, urlUpdateQueryText)

import           WeiXin.PublicPlatform.Types
import           WeiXin.PublicPlatform.Utils
import           WeiXin.PublicPlatform.WS
import           WeiXin.PublicPlatform.XmlUtils


-- | component_verify_ticket
newtype ComponentVerifyTicket = ComponentVerifyTicket { unComponentVerifyTicket :: Text }
                        deriving (Show, Eq, Ord, ToJSON, FromJSON, PersistField, PersistFieldSql
                                 , NFData
                                 , ToMessage, ToMarkup
                                 )

-- | authorization_code
newtype WxppTpAuthCode = WxppTpAuthCode { unWxppTpAuthCode :: Text }
                        deriving (Show, Eq, Ord, ToJSON, FromJSON, PersistField, PersistFieldSql
                                 , NFData
                                 , ToMessage, ToMarkup
                                 )

-- | refresh token
-- 因为通常跟相应的 AppId 一起使用，所以打包在一起
data WxppTpRefreshToken = WxppTpRefreshToken {
                        tpRefreshTokenData     :: Text
                        , tpRefreshTokenApp    :: WxppAppID
                    }
                    deriving (Show, Eq, Typeable, Generic)


-- | component_access_token
-- 因为通常跟相应的 AppId 一起使用，所以打包在一起
data WxppTpAccessToken = WxppTpAccessToken {
                        tpAccessTokenData     :: Text
                        , tpAccessTokenApp    :: WxppAppID
                    }
                    deriving (Show, Eq, Typeable, Generic)


-- | pre_auth_code
newtype ComponentPreAuthCode = ComponentPreAuthCode { unComponentPreAuthCode :: Text }
                        deriving (Show, Eq, Ord, ToJSON, FromJSON, PersistField, PersistFieldSql
                                 , NFData
                                 , ToMessage, ToMarkup
                                 )


-- | 第三方接口多处用到的类似的XML报文中的真正数据
-- 是授权事件接收URL能收到的全部事件
data WxppTpEvent = WxppTpEventVerifyTicket ComponentVerifyTicket
                   -- ^ component_verify_ticket 事件推送
                   | WxppTpEventUnauthorized WxppAppID
                   -- ^ 取消授权通知：数据为授权方的app id
                   | WxppTpEventAuthorized WxppAppID WxppTpAuthCode UTCTime
                   -- ^ 授权成功通知：授权方的app id, 授权码，过期时间
                   | WxppTpEventUpdateAuthorized WxppAppID WxppTpAuthCode UTCTime
                   -- ^ 授权更新通知：授权方的app id, 授权码，过期时间
                   deriving (Show, Eq)

-- | 授权操作接收操作URL上收到的通知报文
data WxppTpEventNotice = WxppTpEventNotice
                            { tpNoticeComponentAppID :: WxppAppID
                            -- ^ 第三方平台的appid，不是授权方的appid
                            , tpNoticeCreateTime     :: UTCTime
                            -- ^ 事件产生时间
                            , tpNoticeEvent          :: WxppTpEvent
                            }
                            deriving (Show)

-- | 解释推送 WxppTpEventNotice 类似的协议报文明文
wxppTpDiagramFromCursor :: Cursor
                        -> Either String
                            (Either Text WxppTpEventNotice)
                            -- ^ 考虑到微信经常不加通知地增加各种事件通知类型
                            -- 明确处理可能出现的不明事件通知
                            -- Left XXX 为不明白的事件通知类型
                            -- Right 才是真正的事件通知
wxppTpDiagramFromCursor cursor = do
  info_type_str <- get_ele_s "InfoType"
  app_id <- fmap WxppAppID $ get_ele_s "AppId"
  tt <- get_ele_s "CreateTime"
              >>= maybe
                      (Left $ "Failed to parse CreateTime")
                      (return . epochIntToUtcTime)
                  . simpleParseDecT

  m_evt <- case info_type_str of
           "component_verify_ticket" -> Just <$> parse_verify_ticket
           "unauthorized"            -> Just <$> parse_unauthorized
           "authorized"              -> Just <$> parse_authorized
           "updateauthorized"        -> Just <$> parse_update_authorized
           _                         -> return Nothing


  case m_evt of
    Nothing   -> return $ Left info_type_str
    Just evt  -> return $ Right $ WxppTpEventNotice app_id tt evt

  where
    get_ele_s = getElementContent cursor

    parse_verify_ticket = do
      WxppTpEventVerifyTicket . ComponentVerifyTicket <$> get_ele_s "ComponentVerifyTicket"

    parse_unauthorized = do
      WxppTpEventUnauthorized . WxppAppID <$> get_ele_s "AuthorizerAppid"

    parse_authorized = do
      tt <- get_ele_s "AuthorizationCodeExpiredTime"
                  >>= maybe
                          (Left $ "Failed to parse AuthorizationCodeExpiredTime")
                          (return . epochIntToUtcTime)
                      . simpleParseDecT

      WxppTpEventAuthorized <$> (WxppAppID <$> get_ele_s "AuthorizerAppid")
                            <*> (WxppTpAuthCode <$> get_ele_s "AuthorizationCode")
                            <*> pure tt

    parse_update_authorized = do
      tt <- get_ele_s "AuthorizationCodeExpiredTime"
                  >>= maybe
                          (Left $ "Failed to parse AuthorizationCodeExpiredTime")
                          (return . epochIntToUtcTime)
                      . simpleParseDecT

      WxppTpEventUpdateAuthorized <$> (WxppAppID <$> get_ele_s "AuthorizerAppid")
                                  <*> (WxppTpAuthCode <$> get_ele_s "AuthorizationCode")
                                  <*> pure tt



-- | component_access_token 返回报文
data WxppTpAccessTokenResp = WxppTpAccessTokenResp
                                  Text
                                  Int

instance FromJSON WxppTpAccessTokenResp where
  parseJSON = withObject "WxppTpAccessTokenResp" $ \o -> do
    WxppTpAccessTokenResp
      <$> o .: "component_access_token"
      <*> o .: "expires_in"


-- | 调用远程接口，取得WxppTpAccessToken
wxppTpGetWxppTpAccessToken :: (WxppApiMonad env m)
                              => WxppAppID
                              -> WxppAppSecret
                              -> ComponentVerifyTicket
                              -> m (WxppTpAccessToken, NominalDiffTime)
wxppTpGetWxppTpAccessToken app_id secret verify_ticket = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_component_token"
      post_data = object [ "component_appid" .= app_id
                         , "component_appsecret" .= secret
                         , "component_verify_ticket" .= verify_ticket
                         ]

  WxppTpAccessTokenResp atk_raw ttl <- liftIO (WS.post sess url post_data)
          >>= asWxppWsResponseNormal'

  return (WxppTpAccessToken atk_raw app_id, fromIntegral ttl)


-- | component_access_token 返回报文
data ComponentPreAuthCodeResp = ComponentPreAuthCodeResp
                                  Text
                                  Int

instance FromJSON ComponentPreAuthCodeResp where
  parseJSON = withObject "ComponentPreAuthCodeResp" $ \o -> do
    ComponentPreAuthCodeResp
      <$> o .: "pre_auth_code"
      <*> o .: "expires_in"


-- | 调用远程接口，取得 ComponentPreAuthCode
wxppTpGetComponentPreAuthCode :: (WxppApiMonad env m)
                              => WxppTpAccessToken
                              -> m (ComponentPreAuthCode, NominalDiffTime)
wxppTpGetComponentPreAuthCode atk = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_create_preauthcode"
      post_data = object [ "component_appid" .= app_id
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  ComponentPreAuthCodeResp code_raw ttl <- liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseNormal'

  return (ComponentPreAuthCode code_raw, fromIntegral ttl)
  where
    WxppTpAccessToken atk_raw app_id = atk



-- | 代表公众号授权给开发者的权限集
data WxppTpAuthFuncCategory = WxppTpAuthFuncMsg                       -- ^ 消息管理
                               | WxppTpAuthFuncUser                   -- ^ 用户管理
                               | WxppTpAuthFuncAccount                -- ^ 帐号服务
                               | WxppTpAuthFuncWebPage                -- ^ 网页服务
                               | WxppTpAuthFuncShop                   -- ^ 微信小店
                               | WxppTpAuthFuncMultiCustomerService   -- ^ 微信多客服
                               | WxppTpAuthFuncPropagate              -- ^ 群发与通知
                               | WxppTpAuthFuncCard                   -- ^ 微信卡券
                               | WxppTpAuthFuncScan                   -- ^ 微信扫一扫
                               | WxppTpAuthFuncWifi                   -- ^ 微信连WIFI
                               | WxppTpAuthFuncMaterial               -- ^ 素材管理
                               | WxppTpAuthFuncShake                  -- ^ 微信摇周边
                               | WxppTpAuthFuncOutlet                 -- ^ 微信门店
                               | WxppTpAuthFuncPay                    -- ^ 微信支付
                               | WxppTpAuthFuncMenu                   -- ^ 自定义菜单
                               deriving (Show, Eq, Ord, Bounded)

instance Enum WxppTpAuthFuncCategory where
  fromEnum WxppTpAuthFuncMsg                  = 1
  fromEnum WxppTpAuthFuncUser                 = 2
  fromEnum WxppTpAuthFuncAccount              = 3
  fromEnum WxppTpAuthFuncWebPage              = 4
  fromEnum WxppTpAuthFuncShop                 = 5
  fromEnum WxppTpAuthFuncMultiCustomerService = 6
  fromEnum WxppTpAuthFuncPropagate            = 7
  fromEnum WxppTpAuthFuncCard                 = 8
  fromEnum WxppTpAuthFuncScan                 = 9
  fromEnum WxppTpAuthFuncWifi                 = 10
  fromEnum WxppTpAuthFuncMaterial             = 11
  fromEnum WxppTpAuthFuncShake                = 12
  fromEnum WxppTpAuthFuncOutlet               = 13
  fromEnum WxppTpAuthFuncPay                  = 14
  fromEnum WxppTpAuthFuncMenu                 = 15

  toEnum 1  = WxppTpAuthFuncMsg
  toEnum 2  = WxppTpAuthFuncUser
  toEnum 3  = WxppTpAuthFuncAccount
  toEnum 4  = WxppTpAuthFuncWebPage
  toEnum 5  = WxppTpAuthFuncShop
  toEnum 6  = WxppTpAuthFuncMultiCustomerService
  toEnum 7  = WxppTpAuthFuncPropagate
  toEnum 8  = WxppTpAuthFuncCard
  toEnum 9  = WxppTpAuthFuncScan
  toEnum 10 = WxppTpAuthFuncWifi
  toEnum 11 = WxppTpAuthFuncMaterial
  toEnum 12 = WxppTpAuthFuncShake
  toEnum 13 = WxppTpAuthFuncOutlet
  toEnum 14 = WxppTpAuthFuncPay
  toEnum 15 = WxppTpAuthFuncMenu
  toEnum x  = error $ "Invalid WxppTpAuthFuncCategory id" <> show x


data WxppTpAuthFuncInfo = WxppTpAuthFuncInfo
                              (Set WxppTpAuthFuncCategory)

instance FromJSON WxppTpAuthFuncInfo where
  parseJSON = withArray "WxppTpAuthFuncInfo" $ \vv -> do
    WxppTpAuthFuncInfo . setFromList <$>
        mapM (jsonParseIdInObj' "WxppTpAuthFuncCategory") (toList vv)


data WxppTpAuthInfo = WxppTpAuthInfo
                          WxppTpAccessToken
                          WxppTpRefreshToken
                          WxppTpAuthFuncInfo
                          Int

instance FromJSON WxppTpAuthInfo where
  parseJSON = withObject "WxppTpAuthInfo" $ \o -> do
    target_app_id <- fmap WxppAppID (o .: "authorizer_appid")
    WxppTpAuthInfo
      <$> (WxppTpAccessToken
            <$> o .: "authorizer_access_token"
            <*> pure target_app_id
          )
      <*> (WxppTpRefreshToken
            <$> o .: "authorizer_refresh_token"
            <*> pure target_app_id
          )
      <*> o .: "func_info"
      <*> o .: "expires_in"


data WxppTpAuthInfoResp = WxppTpAuthInfoResp WxppTpAuthInfo

instance FromJSON WxppTpAuthInfoResp where
  parseJSON = withObject "WxppTpAuthInfoResp" $ \o -> do
              WxppTpAuthInfoResp <$> o .: "authorization_info"


-- | 调用远程接口，取得接口调用凭证及授权信息
wxppTpGetAuthInfo :: (WxppApiMonad env m)
                  => WxppTpAccessToken
                  -> WxppTpAuthCode
                  -> m WxppTpAuthInfoResp
wxppTpGetAuthInfo atk auth_code = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_query_auth"
      post_data = object [ "component_appid" .= app_id
                         , "authorization_code" .= auth_code
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseNormal'

  where
    WxppTpAccessToken atk_raw app_id = atk


data WxppTpRefreshTokensRawResp = WxppTpRefreshTokensRawResp
                                      Text  -- access token
                                      Text  -- refresh token
                                      Int

instance FromJSON WxppTpRefreshTokensRawResp where
  parseJSON = withObject "WxppTpRefreshTokensRep" $ \o -> do
    WxppTpRefreshTokensRawResp
      <$> o .: "authorizer_access_token"
      <*> o .: "authorizer_refresh_token"
      <*> o .: "expires_in"


data WxppTpRefreshTokensResp = WxppTpRefreshTokensResp
                                    AccessToken
                                    WxppTpRefreshToken
                                    NominalDiffTime

-- | 调用远程接口: 获取（刷新）授权公众号的接口调用凭据（令牌）
wxppTpRefreshTokens :: (WxppApiMonad env m)
                    => WxppTpAccessToken
                    -> WxppTpRefreshToken
                    -> m WxppTpRefreshTokensResp
wxppTpRefreshTokens atk refresh_token = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_authorizer_token"
      post_data = object [ "component_appid" .= app_id
                         , "authorizer_appid" .= target_app_id
                         , "authorizer_refresh_token" .= old_refresh_token_raw 
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  WxppTpRefreshTokensRawResp new_atk_raw refresh_token_raw ttl <-
    liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseNormal'

  return $ WxppTpRefreshTokensResp
              (AccessToken new_atk_raw target_app_id)
              (WxppTpRefreshToken refresh_token_raw target_app_id)
              (fromIntegral ttl)
  where
    WxppTpAccessToken atk_raw app_id = atk
    WxppTpRefreshToken old_refresh_token_raw target_app_id = refresh_token



-- | 授权方公众号类型
data TpAppType = TpAppPublisher             -- ^ 订阅号
                 | TpAppPublisherFromOld    -- ^ 由历史老帐号升级后的订阅号
                 | TpAppServer              -- ^ 服务号
                 deriving (Show, Eq, Ord, Bounded)

instance Enum TpAppType where
  fromEnum TpAppPublisher        = 0
  fromEnum TpAppPublisherFromOld = 1
  fromEnum TpAppServer           = 2

  toEnum 0 = TpAppPublisher
  toEnum 1 = TpAppPublisherFromOld
  toEnum 2 = TpAppServer
  toEnum x = error $ "Invalid TpAppType id: " <> show x


-- | 授权方认证类型
-- 从取值看，似乎每个值应该是互斥的
-- 但逻辑上又好似未能完全涵盖全部情况
data TpAppVerifyType = TpAppVerifyNone
                        -- ^ 未认证
                     | TpAppVerifyWeiXin
                        -- ^ 微信认证
                     | TpAppVerifySinaWeibo
                        -- ^ 新浪微博认证
                     | TpAppVerifyTxWeibo
                        -- ^ 腾讯微博认证
                     | TpAppVerifyQualifiedNotName
                        -- ^ 已资质认证通过，还未通过名称认证
                     | TpAppVerifyQualifiedNotNameSinaWeibo
                        -- ^ 已资质认证通过，还未通过名称认证，但通过了新浪微博认证
                     | TpAppVerifyQualifiedNotNameTxWeibo
                        -- ^ 已资质认证通过，还未通过名称认证，但通过了腾讯微博认证
                     deriving (Show, Eq, Ord, Bounded)

instance Enum TpAppVerifyType where
  fromEnum TpAppVerifyNone                      = -1
  fromEnum TpAppVerifyWeiXin                    = 0
  fromEnum TpAppVerifySinaWeibo                 = 1
  fromEnum TpAppVerifyTxWeibo                   = 2
  fromEnum TpAppVerifyQualifiedNotName          = 3
  fromEnum TpAppVerifyQualifiedNotNameSinaWeibo = 4
  fromEnum TpAppVerifyQualifiedNotNameTxWeibo   = 5

  toEnum (-1) = TpAppVerifyNone
  toEnum 0  = TpAppVerifyWeiXin
  toEnum 1  = TpAppVerifySinaWeibo
  toEnum 2  = TpAppVerifyTxWeibo
  toEnum 3  = TpAppVerifyQualifiedNotName
  toEnum 4  = TpAppVerifyQualifiedNotNameSinaWeibo
  toEnum 5  = TpAppVerifyQualifiedNotNameTxWeibo
  toEnum x  = error $ "Invalid TpAppVerifyType id: " <> show x


-- | 文档中的 business_info 字段的值
-- 从内容看，实际上是各种功能的开关值
-- 因此我把它们理解为公众号的＂能力＂
data TpAppAbility = TpAppCanOutlet
                  | TpAppCanScan
                  | TpAppCanPay
                  | TpAppCanCard
                  | TpAppCanShake
                  deriving (Show, Eq, Ord, Enum, Bounded)


-- | 授权方公众号的基本信息
-- 注意：这个信息不包含app id及qrcode url
data AuthorizerInfo = AuthorizerInfo
  { tpAuthorizerNickname   :: Text
  , tpAuthorizerHeadImgUrl :: UrlText
  , tpAuthorizerUserName   :: WeixinUserName
  , tpAuthorizerAppType    :: TpAppType
  , tpAuthorizerVerifyType :: TpAppVerifyType
  , tpAuthorizerAbility    :: Set TpAppAbility
  }

instance FromJSON AuthorizerInfo where
  parseJSON = withObject "AuthorizerInfo" $ \o -> do
    AuthorizerInfo  <$> o .: "nick_name"
                    <*> o .: "head_img"
                    <*> o .: "user_name"
                    <*> (o .: "service_type_info" >>= jsonParseIdInObj "TpAppType")
                    <*> (o .: "verify_type_info" >>= jsonParseIdInObj "TpAppVerifyType")
                    <*> (o .: "business_info" >>= parse_business_info)

    where
      parse_business_info o = do
        let perm_map = [ ("open_store", TpAppCanOutlet)
                       , ("open_scan", TpAppCanScan)
                       , ("open_pay", TpAppCanPay)
                       , ("open_card", TpAppCanCard)
                       , ("open_shake", TpAppCanShake)
                       ]

        liftM (setFromList . catMaybes) $
          forM perm_map $ \(name, perm) -> do
            i <- o .:? name .!= (1 :: Int)
            if i /= 0
               then return $ Just perm
               else return Nothing


-- | 获取授权方的公众号帐号基本信息接口报文
-- 实际上，这个报文包含的公众号的基本信息及授权行为的基本信息
-- 注意：这个类型的结构内部层次与报文略有不同
data AuthorizationPack = AuthorizationPack
  { tpAuthPackAuthorizer :: AuthorizerInfo
  , tpAuthPackQrCodeUrl  :: UrlText
  , tpAuthPackAppId      :: WxppAppID
  , tpAuthPackFuncInfo   :: WxppTpAuthFuncInfo
  }

instance FromJSON AuthorizationPack where
  parseJSON = withObject "AuthorizationPack" $ \o -> do
    o2 <- o .: "authorization_info"
    AuthorizationPack <$> o .: "authorizer_info"
                      <*> o .: "qrcode_url"
                      <*> o2 .: "appid"
                      <*> o2 .: "func_info"


-- | 调用远程接口:授权公众号帐号基本信息
wxppTpGetAuthorizationPack :: (WxppApiMonad env m)
                           => WxppTpAccessToken
                           -> WxppAppID
                           -> m AuthorizationPack
wxppTpGetAuthorizationPack atk target_app_id = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_authorizer_info"
      post_data = object [ "component_appid" .= app_id
                         , "authorizer_appid" .= target_app_id
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseNormal'

  where
    WxppTpAccessToken atk_raw app_id = atk


-- | 授权方选项
-- 包含一个名字，及相应的值
class TpAuthOption a where
  tpAuthOptionName :: Proxy a -> Text
  tpAuthOptionParseValue :: Value -> A.Parser a


-- | 选项：地理位置上报
data TpAuthLocationReport = TpAuthLocationReportNone
                          | TpAuthLocationReportEntry
                          | TpAuthLocationReportPeriodic
                          deriving (Show, Eq, Ord, Bounded)

instance Enum TpAuthLocationReport where
  fromEnum TpAuthLocationReportNone     = 0
  fromEnum TpAuthLocationReportEntry    = 1
  fromEnum TpAuthLocationReportPeriodic = 2

  toEnum 0 = TpAuthLocationReportNone
  toEnum 1 = TpAuthLocationReportEntry
  toEnum 2 = TpAuthLocationReportPeriodic
  toEnum x = error $ "Invalid TpAuthLocationReport Int value: " <> show x

instance ToJSON TpAuthLocationReport where
  toJSON = toJSON . show . fromEnum

instance TpAuthOption TpAuthLocationReport where
  tpAuthOptionName _ = "location_report"

  tpAuthOptionParseValue = withText "TpAuthLocationReport" $ \s -> do
    case s of
      "0" -> return TpAuthLocationReportNone
      "1" -> return TpAuthLocationReportEntry
      "2" -> return TpAuthLocationReportPeriodic
      _   -> fail $ "Invalid TpAuthLocationReport value: " <> unpack s


-- | 选项：语音识别开关
newtype TpAuthVoiceRecognize = TpAuthVoiceRecognize { unTpAuthVoiceRecognize :: Bool }

instance TpAuthOption TpAuthVoiceRecognize where
  tpAuthOptionName _ = "voice_recognize"

  tpAuthOptionParseValue = withText "TpAuthVoiceRecognize" $ \s -> do
    fmap TpAuthVoiceRecognize $
      case s of
        "0" -> return False
        "1" -> return True
        _   -> fail $ "Invalid TpAuthVoiceRecognize value: " <> unpack s

instance ToJSON TpAuthVoiceRecognize where
  toJSON (TpAuthVoiceRecognize b) = toJSON $ show (if b then 1 else 0 :: Int)


-- | 选项：多客服开关
newtype TpAuthCustomerService = TpAuthCustomerService { unTpAuthCustomerService :: Bool }

instance TpAuthOption TpAuthCustomerService where
  tpAuthOptionName _ = "customer_service"

  tpAuthOptionParseValue = withText "TpAuthCustomerService" $ \s -> do
    fmap TpAuthCustomerService $
      case s of
        "0" -> return False
        "1" -> return True
        _   -> fail $ "Invalid TpAuthCustomerService value: " <> unpack s

instance ToJSON TpAuthCustomerService where
  toJSON (TpAuthCustomerService b) = toJSON $ show (if b then 1 else 0 :: Int)


-- | 取选项设置信息的报文
data TpAuthOptionResp a = TpAuthOptionResp
                            WxppAppID -- ^ authorizer app id
                            Text      -- ^ option name
                            a         -- ^ option value

instance TpAuthOption a => FromJSON (TpAuthOptionResp a) where
  parseJSON = withObject "TpAuthOptionResp" $ \o -> do
    TpAuthOptionResp <$> o .: "authorizer_appid"
                     <*> o .: "option_name"
                     <*> (o .: "option_value" >>= tpAuthOptionParseValue)


-- | 调用远程接口:获取授权公众号选项设置信息
wxppTpGetAuthOption :: forall env m a. (WxppApiMonad env m, TpAuthOption a)
                    => WxppTpAccessToken
                    -> WxppAppID
                    -> m a
wxppTpGetAuthOption atk target_app_id = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_get_authorizer_option"
      post_data = object [ "component_appid" .= app_id
                         , "authorizer_appid" .= target_app_id
                         , "option_name" .= tpAuthOptionName (Proxy :: Proxy a)
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  TpAuthOptionResp _target_app_id2 _opt_name2 opt_val <-
    liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseNormal'

  return opt_val

  where
    WxppTpAccessToken atk_raw app_id = atk


-- | 调用远程接口:设置授权公众号选项设置信息
wxppTpSetAuthOption :: forall env m a. (WxppApiMonad env m, TpAuthOption a, ToJSON a)
                    => WxppTpAccessToken
                    -> WxppAppID
                    -> a
                    -> m ()
wxppTpSetAuthOption atk target_app_id opt_val = do
  (sess, url_conf) <- asks (getWreqSession &&& getWxppUrlConfig)
  let url       = wxppUrlConfSecureApiBase url_conf <> "/component/api_set_authorizer_option"
      post_data = object [ "component_appid" .= app_id
                         , "authorizer_appid" .= target_app_id
                         , "option_name" .= tpAuthOptionName (Proxy :: Proxy a)
                         , "option_value" .= opt_val
                         ]
      opt       = defaults & param "component_access_token" .~ [ atk_raw ]

  liftIO (WS.postWith opt sess url post_data)
          >>= asWxppWsResponseVoid

  where
    WxppTpAccessToken atk_raw app_id = atk


-- | 引导用户进入授权页的URL
wxppTpAuthorizePageUrl :: WxppAppID
                       -> ComponentPreAuthCode
                       -> String
                       -> String
wxppTpAuthorizePageUrl app_id pre_auth_code return_url = do
  case m_url of
    Nothing -> error "wxppTpAuthorizePageUrl: failed to construct url"
    Just x  -> x
  where
    base_url  = "https://mp.weixin.qq.com/cgi-bin/componentloginpage"
    m_url     = urlUpdateQueryText
                  (queryTextSetParam
                    [ ("component_appid", Just (unWxppAppID app_id))
                    , ("pre_auth_code", Just (unComponentPreAuthCode pre_auth_code))
                    , ("redirect_uri", Just (pack return_url))
                    ])
                  base_url


--------------------------------------------------------------------------------


safeToEnumB :: (Enum a, Bounded a) => Int -> Maybe a
safeToEnumB = flip lookup $ map (fromEnum &&& id) [minBound .. maxBound]


-- | 解释json的小工具：{id: XXX} 形式表达的值
jsonParseIdInObj :: (Enum a, Bounded a) => String -> Object -> A.Parser a
jsonParseIdInObj type_name o = do
  int_id <- o .: "id"
  case safeToEnumB int_id of
    Nothing -> fail $ "unknown " <> type_name <> " id: " <> show int_id
    Just x  -> return x


jsonParseIdInObj' :: (Enum a, Bounded a) => String -> Value -> A.Parser a
jsonParseIdInObj' type_name = withObject type_name $ jsonParseIdInObj type_name