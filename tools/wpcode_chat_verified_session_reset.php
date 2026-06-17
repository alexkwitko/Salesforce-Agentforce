<?php
if (!defined('ABSPATH')) { exit; }

add_action('wp_footer', function () {
    if (is_admin()) { return; }
    ?>
    <script id="kwitko-chat-verified-session-reset-20260614">
    (function () {
      "use strict";

      var VERSION = "20260614.1";

      function auth() {
        return window.KWITKO_AUTH || {};
      }

      function currentIdentity() {
        var a = auth();
        return a.loggedIn && a.email ? "user:" + String(a.email).toLowerCase() : "guest";
      }

      function clearSalesforceChatSession() {
        try {
          var b = window.embeddedservice_bootstrap;
          if (!b) return;
          if (b.utilAPI && typeof b.utilAPI.clearSession === "function") {
            b.utilAPI.clearSession({ shouldEndSession: true });
          } else if (typeof b.clearSession === "function") {
            b.clearSession({ shouldEndSession: true });
          }
          if (b.userVerificationAPI && typeof b.userVerificationAPI.clearSession === "function") {
            b.userVerificationAPI.clearSession({ shouldEndSession: true });
          }
        } catch (e) {}
      }

      function setHiddenPrechat() {
        try {
          var a = auth();
          if (!a.loggedIn || !a.email) return;
          if (!window.embeddedservice_bootstrap || !embeddedservice_bootstrap.prechatAPI) return;
          embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
            "Kwitko_Logged_In_Email__c": a.email,
            "Kwitko_Logged_In_First_Name__c": a.firstName || ""
          });
        } catch (e) {}
      }

      function sendIdentityToken() {
        try {
          var a = auth();
          if (!a.loggedIn || !a.email || !a.jwtUrl) return;
          if (!window.embeddedservice_bootstrap || !embeddedservice_bootstrap.userVerificationAPI) return;
          fetch(a.jwtUrl, {
            credentials: "include",
            headers: { "X-WP-Nonce": a.nonce || "" }
          })
            .then(function (r) { return r.ok ? r.json() : null; })
            .then(function (j) {
              if (j && j.jwt) {
                embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
                  identityTokenType: "JWT",
                  identityToken: j.jwt
                });
              }
            })
            .catch(function () {});
        } catch (e) {}
      }

      function resetLoggedInStaleGuestConversationOnce() {
        try {
          var id = currentIdentity();
          if (id === "guest") return;
          var key = "kwitko_verified_reset_" + VERSION;
          if (sessionStorage.getItem(key) === id) return;

          clearSalesforceChatSession();
          sessionStorage.setItem(key, id);
          setTimeout(sendIdentityToken, 250);
          setTimeout(setHiddenPrechat, 300);
        } catch (e) {}
      }

      window.addEventListener("onEmbeddedMessagingReady", function () {
        resetLoggedInStaleGuestConversationOnce();
        sendIdentityToken();
        setHiddenPrechat();
      });

      window.addEventListener("onEmbeddedMessagingIdentityTokenExpired", sendIdentityToken);
    })();
    </script>
    <?php
}, 6);
