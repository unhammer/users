{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
module Web.Users.TestSpec
    ( makeUsersSpec )
where

import Web.Users.Types

import Control.Concurrent (threadDelay)
import Data.Aeson
import GHC.Generics
import Test.Hspec
import qualified Data.Text as T

type DummyUser = User DummyDetails

data DummyDetails
   = DummyDetails
   { dd_foo :: Bool
   , _dd_bar :: Int
   } deriving (Show, Eq, Generic)

instance FromJSON DummyDetails
instance ToJSON DummyDetails

mkUser :: T.Text -> T.Text -> DummyUser
mkUser name email =
    User
    { u_name = name
    , u_email = email
    , u_password = PasswordPlain "1234"
    , u_active = False
    , u_more = DummyDetails True 21
    }

assertRight :: Show a => IO (Either a b) -> (b -> IO ()) -> IO ()
assertRight val action =
    do r <- val
       case r of
         Right v -> action v
         Left err -> expectationFailure (show err)

assertLeft :: IO (Either a b) -> String -> (a -> IO ()) -> IO ()
assertLeft val msg action =
    do r <- val
       case r of
         Right _ -> expectationFailure msg
         Left v -> action v

makeUsersSpec :: forall b. UserStorageBackend b => b -> Spec
makeUsersSpec backend =
    before_ (initUserBackend backend) $
    after_ (destroyUserBackend backend) $
    do describe "core user management" $
           do it "should create valid users" $
                 assertRight (createUser backend userA) $ const (return ())
              it "should not allow duplicates" $
                 assertRight (createUser backend userB) $ \_ ->
                     do assertLeft (createUser backend (mkUser "foo2" "bar2@baz.com"))
                                       "succeeded to create foo2 bar2 again" $ \err ->
                            err `shouldBe` UsernameOrEmailAlreadyTaken
                        assertLeft (createUser backend (mkUser "foo2" "asdas@baz.com"))
                                       "succeeded to create foo2 with different email again" $ \err ->
                            err `shouldBe` UsernameOrEmailAlreadyTaken
                        assertLeft (createUser backend (mkUser "asdas" "bar2@baz.com"))
                                       "succeeded to create different user with same email" $ \err ->
                            err `shouldBe` UsernameOrEmailAlreadyTaken
              it "list and count should be correct" $
                 assertRight (createUser backend userA) $ \userId1 ->
                 assertRight (createUser backend userB) $ \userId2 ->
                 do allUsers <- listUsers backend Nothing
                    if and [ (userId1, userA { u_password = PasswordHidden }) `elem` allUsers
                           , (userId2, userB { u_password = PasswordHidden }) `elem` allUsers
                           ]
                    then return ()
                    else expectationFailure $ "create users not in user list:" ++ show allUsers

                    countUsers backend `shouldReturn` 2
              it "updating and loading users should work" $
                 assertRight (createUser backend userA) $ \userIdA ->
                 assertRight (createUser backend userB) $ \_ ->
                     do assertRight (updateUser backend userIdA (\(user :: DummyUser) -> user { u_name = "changed" })) $ const (return ())
                        assertLeft (updateUser backend userIdA (\(user :: DummyUser) -> user { u_name = "foo2" }))
                                       "succeeded to set username to already used username" $ \err ->
                            err `shouldBe` UsernameOrEmailAlreadyExists
                        assertLeft (updateUser backend userIdA (\(user :: DummyUser) -> user { u_email = "bar2@baz.com" }))
                                       "succeeded to set email to already used email" $ \err ->
                            err `shouldBe` UsernameOrEmailAlreadyExists
                        updateUserDetails backend userIdA (\d -> d { dd_foo = False })
                        userA' <- getUserById backend userIdA
                        userA' `shouldBe`
                               (Just $ userA
                                { u_name = "changed"
                                , u_password = PasswordHidden
                                , u_more =
                                    (u_more userA)
                                    { dd_foo = False
                                    }
                                })
              it "deleting users should work" $
                 assertRight (createUser backend userA) $ \userIdA ->
                 assertRight (createUser backend userB) $ \userIdB ->
                     do deleteUser backend userIdA
                        (allUsers :: [(UserId b, DummyUser)]) <- listUsers backend Nothing
                        (map fst allUsers) `shouldBe` [userIdB]
                        getUserById backend userIdA `shouldReturn` (Nothing :: Maybe DummyUser)
              it "reusing a deleted users name should work" $
                 assertRight (createUser backend userA) $ \userIdA ->
                     do deleteUser backend userIdA
                        assertRight (createUser backend userA) $ const (return ())
       describe "initialisation" $
           do it "calling initUserBackend multiple times should not result in errors" $
                 assertRight (createUser backend userA) $ \userIdA ->
                 do initUserBackend backend
                    userA' <- getUserById backend userIdA
                    userA' `shouldBe` (Just $ userA { u_password = PasswordHidden })
       describe "authentification" $
           do it "auth as valid user with username should work" $
                 withAuthedUser $ const (return ())
              it "auth as valid user with email should work" $
                 withAuthedUser' "bar@baz.com" "1234" 500 0 $ const (return ())
              it "auth with invalid credentials should fail" $
                 assertRight (createUser backend userA) $ \_ ->
                 do authUser backend "foo" "aaaa" 500 `shouldReturn` Nothing
                    authUser backend "foo" "123" 500 `shouldReturn` Nothing
                    authUser backend "bar@baz.com" "123" 500 `shouldReturn` Nothing
                    authUser backend "bar@baz.com' OR 1 = 1 --" "123" 500 `shouldReturn` Nothing
                    authUser backend "bar@baz.com' OR 1 = 1; --" "' OR 1 = 1; --" 500 `shouldReturn` Nothing
              it "destroy session should really remove the session" $
                 withAuthedUser $ \(sessionId, _) ->
                     do destroySession backend sessionId
                        verifySession backend sessionId 0 `shouldReturn` (Nothing :: Maybe (UserId b))
              it "sessions should time out 1" $
                 withAuthedUserT 1 0 $ \(sessionId, _) ->
                 do threadDelay (seconds 1)
                    housekeepBackend backend
                    verifySession backend sessionId 0 `shouldReturn` (Nothing :: Maybe (UserId b))
              it "sessions should time out 2" $
                 withAuthedUserT 1 1 $ \(sessionId, _) ->
                 do threadDelay (seconds 2)
                    verifySession backend sessionId 0 `shouldReturn` (Nothing :: Maybe (UserId b))
       describe "password reset" $
          do it "generates a valid token for a user" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do token <- requestPasswordReset backend userIdA 500
                       verifyPasswordResetToken backend token `shouldReturn` (Just (userA { u_password = PasswordHidden }) :: Maybe DummyUser)
             it "a valid token should reset the password" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do withAuthedUserNoCreate "foo" "1234" 500 0 userIdA $ const (return ()) -- old login
                       token <- requestPasswordReset backend userIdA 500
                       housekeepBackend backend
                       verifyPasswordResetToken backend token `shouldReturn` (Just (userA { u_password = PasswordHidden }) :: Maybe DummyUser)
                       assertRight (applyNewPassword backend token "foobar") $ const $ return ()
                       withAuthedUserNoCreate "foo" "foobar" 500 0 userIdA $ const (return ()) -- new login
             it "expired tokens should not do any harm" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do withAuthedUserNoCreate "foo" "1234" 500 0 userIdA $ const (return ()) -- old login
                       token <- requestPasswordReset backend userIdA 1
                       threadDelay (seconds 1)
                       verifyPasswordResetToken backend token `shouldReturn` (Nothing :: Maybe DummyUser)
                       assertLeft (applyNewPassword backend token "foobar")
                                      "Reset password with expired token" $ const $ return ()
                       withAuthedUserNoCreate "foo" "1234" 500 0 userIdA $ const (return ()) -- still old login
             it "invalid tokens should not do any harm" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do withAuthedUserNoCreate "foo" "1234" 500 0 userIdA $ const (return ()) -- old login
                       let token = PasswordResetToken "Foooooooo!!!!"
                       verifyPasswordResetToken backend token `shouldReturn` (Nothing :: Maybe DummyUser)
                       assertLeft (applyNewPassword backend token "foobar")
                                      "Reset password with random token" $ const $ return ()
                       withAuthedUserNoCreate "foo" "1234" 500 0 userIdA $ const (return ()) -- still old login
       describe "user activation" $
          do it "activates a user with a valid activation token" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do token <- requestActivationToken backend userIdA 500
                       housekeepBackend backend
                       assertRight (activateUser backend token) $ const $ return ()
                       userA' <- getUserById backend userIdA
                       userA' `shouldBe`
                                  (Just $ userA
                                   { u_active = True
                                   , u_password = PasswordHidden
                                   })
             it "does not allow expired tokens to activate a user" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do token <- requestActivationToken backend userIdA 1
                       threadDelay (seconds 1)
                       assertLeft (activateUser backend token) "invalid token activated user" $ const $ return ()
                       userA' <- getUserById backend userIdA
                       userA' `shouldBe`
                                  (Just $ userA
                                   { u_active = False
                                   , u_password = PasswordHidden
                                   })
             it "does not allow invalid tokens to activate a user" $
                assertRight (createUser backend userA) $ \userIdA ->
                    do let token = ActivationToken "aaaasdlasdkaklasdlkasjdl"
                       assertLeft (activateUser backend token) "invalid token activated user" $ const $ return ()
                       userA' <- getUserById backend userIdA
                       userA' `shouldBe`
                                  (Just $ userA
                                   { u_active = False
                                   , u_password = PasswordHidden
                                   })
    where
      seconds x = x * 1000000
      userA = mkUser "foo" "bar@baz.com"
      userB = mkUser "foo2" "bar2@baz.com"
      withAuthedUser = withAuthedUser' "foo" "1234" 500 0
      withAuthedUserT = withAuthedUser' "foo" "1234"
      withAuthedUser' username pass sTime extTime action =
          assertRight (createUser backend userA) $ \userIdA ->
          withAuthedUserNoCreate username pass sTime extTime userIdA action
      withAuthedUserNoCreate username pass sTime extTime userIdA action =
          do mAuthRes <- authUser backend username pass sTime
             case mAuthRes of
               Nothing ->
                   expectationFailure $ "Can not authenticate as user " ++ show username
               Just sessionId ->
                   do verifySession backend sessionId extTime `shouldReturn` Just userIdA
                      action (sessionId, userIdA)