module Main where

import ClassyPrelude hiding ((<>))
import Control.Monad.Logger
import Options.Applicative
import qualified Data.ByteString            as B
import qualified Data.Yaml                  as Y
-- import Control.Monad.Reader                 (asks)

import System.Log.FastLogger                (pushLogStr, newStderrLoggerSet
                                            , LoggerSet, LogStr)

import WeiXin.PublicPlatform.AutoReplyRules
import WeiXin.PublicPlatform.Menu
-- import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Security

data ManageCmd = QueryAutoReplyRules
                | QueryMenu
                deriving (Show, Eq, Ord)


data Options = Options {
                optAppID        :: WxppAppID
                , optAppToken   :: Maybe Token
                , optAppSecret  :: WxppAppSecret
                , optAppAesKey  :: Maybe AesKey
                , optVerbose    :: Int
                , optCommand    :: ManageCmd
                }


manageCmdParser :: Parser ManageCmd
manageCmdParser = subparser $
    command "query-autoreply-rules"
        (info (pure QueryAutoReplyRules)
            (progDesc "取当前自动回复规则设置"))
    <> command "query-menu"
        (info (pure QueryMenu)
            (progDesc "取菜单配置"))

aesKeyReader ::
#if MIN_VERSION_optparse_applicative(0, 11, 0)
    ReadM AesKey
aesKeyReader = do
    s <- str
#else
    (Monad m) => String -> m AesKey
aesKeyReader s = do
#endif
    either fail return $ decodeBase64AesKey $ fromString s

optionsParse :: Parser Options
optionsParse = Options
                <$> (WxppAppID . fromString <$> strOption (long "app-id"
                                                <> metavar "APP_ID"
                                                <> help "App ID String"))
                <*> (optional $ Token . fromString <$> strOption (long "token"
                                                <> metavar "TOKEN"
                                                <> help "App Token String"))
                <*> (WxppAppSecret . fromString <$> strOption
                                    (long "secret"
                                    <> metavar "SECRET"
                                    <> help "App Secret String"))
                <*> (optional $ option aesKeyReader
                                    (long "aes-key"
                                    <> metavar "AES_KEY"
                                    <> help "Base64-encoded App AES Key"))
                <*> (option auto
                        $ long "verbose" <> short 'v' <> value 1
                        <> metavar "LEVEL"
                        <> help "Verbose Level (0 - 3)")
                <*> manageCmdParser


start :: (MonadLogger m, MonadThrow m, MonadIO m) => ReaderT Options m ()
start = do
    opts <- ask
    let app_id = optAppID opts
        app_secret = optAppSecret opts
        get_atk = do
            AccessTokenResp atk _ttl <- refreshAccessToken' app_id app_secret
            return atk

    case optCommand opts of

        QueryAutoReplyRules -> do
            atk <- get_atk
            obj <- wxppQueryOriginAutoReplyRules atk
            liftIO $ B.putStr $ Y.encode obj

        QueryMenu -> do
            atk <- get_atk
            result <- wxppQueryMenuConfig atk
            liftIO $ B.putStr $ Y.encode result


start' :: Options -> IO ()
start' opts = do
    logger_set <- newStderrLoggerSet 0
    runLoggingT
        (runReaderT start opts)
        (appLogger logger_set (optVerbose opts))

appLogger :: LoggerSet -> Int -> Loc -> LogSource -> LogLevel -> LogStr -> IO ()
appLogger logger_set verbose loc src level ls = do
    let should_log = case level of
                        LevelOther {}   -> True
                        _               -> level `elem` lv_by_v verbose

    if should_log
        then pushLogStr logger_set $ defaultLogStr loc src level ls
        else return ()
    where
        lv_by_v lv
            | lv <= 0   = [ LevelError]
            | lv == 1   = [ LevelError, LevelWarn ]
            | lv == 2   = [ LevelError, LevelWarn, LevelInfo ]
            | otherwise = [ LevelError, LevelWarn, LevelInfo, LevelDebug ]

main :: IO ()
main = execParser opts >>= start'
    where
        opts = info (helper <*> optionsParse)
                ( fullDesc
                    <> progDesc "执行一些微信公众平台管理查询操作\n警告：执行操作会更新 access token，服务器使用中的token可能会失效"
                    <> header "wxpp-manage - 微信公众平台管理查询小工具"
                    )
