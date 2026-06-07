@isTest
private class LoginLinkServiceTest {
    @isTest static void returnsSignInLink() {
        LoginLinkService.Result r = LoginLinkService.getSignInLink(new List<LoginLinkService.Request>{ new LoginLinkService.Request() })[0];
        System.assertEquals(true, r.success);
        System.assert(r.linkUrl.endsWith('/?kwitko_login=1'), r.linkUrl);
        System.assertEquals('Sign in to your account', r.linkTitle);
    }
}
