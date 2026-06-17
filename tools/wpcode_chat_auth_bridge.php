<?php
/**
 * Kwitko Agentforce Chat Auth Bridge (WPCode PHP snippet)
 * ------------------------------------------------------
 * Run Everywhere. Replaces the older identify-only snippet.
 *
 * Provides:
 *   GET    /wp-json/kwitko/v1/me
 *   GET    /wp-json/kwitko/v1/jwt
 *   GET    /wp-json/kwitko/v1/identify
 *   POST   /wp-json/kwitko/v1/identify
 *   DELETE /wp-json/kwitko/v1/identify
 *
 * The reliable Agentforce auth path is the hidden prechat field
 * Kwitko_Logged_In_Email__c. JWT is kept as a best-effort supplement only.
 */

if (!defined('ABSPATH')) { exit; }

if (!defined('KWITKO_CHAT_AUTH_BRIDGE_VERSION')) {
    define('KWITKO_CHAT_AUTH_BRIDGE_VERSION', '20260615.6');
}

if (!function_exists('kwitko_chat_auth_b64url')) {
    function kwitko_chat_auth_b64url($data) {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }
}

if (!function_exists('kwitko_chat_auth_hmac_secret')) {
    function kwitko_chat_auth_hmac_secret() {
        if (defined('KWITKO_WHK_SECRET')) { return KWITKO_WHK_SECRET; }
        if (defined('KWITKO_CART_SECRET')) { return KWITKO_CART_SECRET; }
        return '';
    }
}

if (!function_exists('kwitko_chat_auth_mint_jwt')) {
    function kwitko_chat_auth_mint_jwt($email, $first_name = '') {
        if (!defined('KWITKO_JWT_PRIVATE_KEY')) {
            return new WP_Error('no_key', 'JWT key not configured', array('status' => 500));
        }

        $iss = defined('KWITKO_JWT_ISS') ? KWITKO_JWT_ISS : 'kwitko-coffee-store';
        $kid = defined('KWITKO_JWT_KID') ? KWITKO_JWT_KID : 'kwitko-key-1';
        $now = time();

        $header = array('alg' => 'RS256', 'typ' => 'JWT', 'kid' => $kid);
        $payload = array(
            'sub' => strtolower($email),
            'iss' => $iss,
            'iat' => $now,
            'exp' => $now + 3600,
            'email' => strtolower($email),
            'first_name' => $first_name,
        );

        $signing_input = kwitko_chat_auth_b64url(wp_json_encode($header)) . '.' . kwitko_chat_auth_b64url(wp_json_encode($payload));
        $sig = '';
        $ok = openssl_sign($signing_input, $sig, KWITKO_JWT_PRIVATE_KEY, OPENSSL_ALGO_SHA256);
        if (!$ok) {
            return new WP_Error('sign_failed', 'Could not sign JWT', array('status' => 500));
        }
        return $signing_input . '.' . kwitko_chat_auth_b64url($sig);
    }
}

add_action('rest_api_init', function () {
    register_rest_route('kwitko/v1', '/me', array(
        'methods' => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function () {
            if (is_user_logged_in()) {
                $u = wp_get_current_user();
                return array(
                    'logged_in' => true,
                    'email' => $u->user_email,
                    'first_name' => $u->first_name ? $u->first_name : $u->display_name,
                    'bridge_version' => KWITKO_CHAT_AUTH_BRIDGE_VERSION,
                );
            }
            return array(
                'logged_in' => false,
                'bridge_version' => KWITKO_CHAT_AUTH_BRIDGE_VERSION,
            );
        },
    ));

    register_rest_route('kwitko/v1', '/jwt', array(
        'methods' => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function () {
            if (!is_user_logged_in()) {
                return new WP_Error('not_logged_in', 'Sign in first.', array('status' => 401));
            }
            $u = wp_get_current_user();
            $jwt = kwitko_chat_auth_mint_jwt($u->user_email, $u->first_name);
            if (is_wp_error($jwt)) { return $jwt; }
            return array(
                'jwt' => $jwt,
                'email' => $u->user_email,
                'first_name' => $u->first_name ? $u->first_name : $u->display_name,
                'bridge_version' => KWITKO_CHAT_AUTH_BRIDGE_VERSION,
            );
        },
    ));

    register_rest_route('kwitko/v1', '/identify', array(
        array(
            'methods' => 'GET',
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if (!$token) { return array('email' => '', 'firstName' => ''); }
                $data = get_transient('kwitko_identify_' . $token);
                return $data ? $data : array('email' => '', 'firstName' => '');
            },
        ),
        array(
            'methods' => 'POST',
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $raw = $req->get_body();
                $sig = $req->get_header('X-Kwitko-Signature');
                $secret = kwitko_chat_auth_hmac_secret();
                if ($secret) {
                    $calc = base64_encode(hash_hmac('sha256', $raw, $secret, true));
                    if (!hash_equals($calc, (string) $sig)) {
                        return new WP_Error('bad_sig', 'Invalid signature', array('status' => 401));
                    }
                }
                $body = json_decode($raw, true);
                $token = isset($body['token']) ? sanitize_text_field($body['token']) : '';
                $email = isset($body['email']) ? sanitize_email($body['email']) : '';
                if (!$token || !$email) {
                    return new WP_Error('missing', 'token and email required', array('status' => 400));
                }
                set_transient('kwitko_identify_' . $token, array(
                    'email' => $email,
                    'firstName' => isset($body['firstName']) ? sanitize_text_field($body['firstName']) : '',
                ), 30 * MINUTE_IN_SECONDS);
                return array('ok' => true);
            },
        ),
        array(
            'methods' => 'DELETE',
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if ($token) { delete_transient('kwitko_identify_' . $token); }
                return array('ok' => true);
            },
        ),
    ));
});

add_action('wp_footer', function () {
    $current_user = is_user_logged_in() ? wp_get_current_user() : null;
    $first_name = $current_user ? ($current_user->first_name ? $current_user->first_name : $current_user->display_name) : '';
    ?>
    <script id="kwitko-chat-auth-bridge">
    (function () {
      "use strict";
      var VERSION = "<?php echo esc_js(KWITKO_CHAT_AUTH_BRIDGE_VERSION); ?>";
      var CFG = window.KWITKO_AUTH = Object.assign({}, window.KWITKO_AUTH || {}, {
        meUrl: "<?php echo esc_url_raw(rest_url('kwitko/v1/me')); ?>",
        jwtUrl: "<?php echo esc_url_raw(rest_url('kwitko/v1/jwt')); ?>",
        identifyUrl: "<?php echo esc_url_raw(rest_url('kwitko/v1/identify')); ?>",
        loginUrl: "<?php echo esc_url(home_url('/my-account-2/')); ?>",
        nonce: "<?php echo esc_attr(wp_create_nonce('wp_rest')); ?>",
        loggedIn: <?php echo $current_user ? 'true' : 'false'; ?>,
        email: "<?php echo $current_user ? esc_js($current_user->user_email) : ''; ?>",
        firstName: "<?php echo esc_js($first_name); ?>",
        controllerVersion: VERSION
      });

      window.KWITKO_CHAT_AUTH_BRIDGE_VERSION = VERSION;
      var messagingReady = false;

      function token() {
        try {
          var t = localStorage.getItem("kwitko_token");
          if (!t) {
            t = "kc-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
            localStorage.setItem("kwitko_token", t);
          }
          return t;
        } catch (e) {
          return "";
        }
      }

      function fetchJSON(url) {
        return fetch(url, {
          credentials: "include",
          headers: { "X-WP-Nonce": CFG.nonce || "" }
        }).then(function (r) {
          return r.ok ? r.json() : null;
        });
      }

      function fireDataCloudIdentify(email, firstName, lastName) {
        var identifyFn =
          typeof window.kwitkoDataCloudIdentify === "function"
            ? window.kwitkoDataCloudIdentify
            : typeof window.kwitkoIdentify === "function"
              ? window.kwitkoIdentify
              : null;
        if (!email || !identifyFn) return false;
        if (window.__kwitkoIdentifyDone === email) return true;
        try {
          identifyFn(email, firstName || "", lastName || "");
          window.__kwitkoIdentifyDone = email;
          return true;
        } catch (e) {
          return false;
        }
      }

      function setHiddenPrechatFields() {
        if (!CFG.loggedIn || !CFG.email) return;
        fireDataCloudIdentify(CFG.email, CFG.firstName || "", "");
        if (!messagingReady) return;
        try {
          if (
            window.embeddedservice_bootstrap &&
            embeddedservice_bootstrap.prechatAPI &&
            typeof embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields === "function"
          ) {
            embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
              "Kwitko_Logged_In_Email__c": CFG.email,
              "Kwitko_Logged_In_First_Name__c": CFG.firstName || ""
            });
            var cartToken = token();
            if (cartToken) {
              try {
                embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
                  "Kwitko_Cart_Token__c": cartToken
                });
              } catch (e) {}
            }
          }
        } catch (e) {}
      }

      function resetMessagingOnLogout() {
        try { localStorage.removeItem("kwitko_token"); } catch (e) {}
        window.__kwitkoIdentifyDone = null;
        try {
          if (typeof window.kwitkoDataCloudReset === "function") {
            window.kwitkoDataCloudReset();
          } else {
            localStorage.setItem("kwitko_dc_reset_requested", String(Date.now()));
          }
        } catch (e) {}
        try {
          var b = window.embeddedservice_bootstrap;
          if (b) {
            if (b.utilAPI && typeof b.utilAPI.clearSession === "function") { b.utilAPI.clearSession({ shouldEndSession: true }); }
            else if (typeof b.clearSession === "function") { b.clearSession({ shouldEndSession: true }); }
            if (b.utilAPI && typeof b.utilAPI.removeAllComponents === "function") { b.utilAPI.removeAllComponents(); }
            if (b.userVerificationAPI && typeof b.userVerificationAPI.clearSession === "function") { b.userVerificationAPI.clearSession(); }
          }
        } catch (e) {}
      }

      function endStaleConversation() {
        // End a persisted conversation that belongs to a different identity, but KEEP
        // the launcher (no removeAllComponents) so a fresh conversation can start.
        try {
          window.__kwitkoIdentifyDone = null;
          var b = window.embeddedservice_bootstrap;
          if (b) {
            if (b.utilAPI && typeof b.utilAPI.clearSession === "function") { b.utilAPI.clearSession({ shouldEndSession: true }); }
            else if (typeof b.clearSession === "function") { b.clearSession({ shouldEndSession: true }); }
          }
        } catch (e) {}
      }
      function currentIdentity() {
        return (CFG.loggedIn && CFG.email) ? ("user:" + String(CFG.email).toLowerCase()) : "guest";
      }
      function ensureFreshConversationForIdentity() {
        try {
          var cur = currentIdentity();
          var prev = localStorage.getItem("kwitko_chat_identity");
          if (prev !== null && prev !== cur) {
            // Persisted conversation belongs to a different identity — end it so a
            // fresh conversation is created with the correct routing attributes.
            endStaleConversation();
          }
          localStorage.setItem("kwitko_chat_identity", cur);
        } catch (e) {}
      }

      function refreshMe() {
        return fetchJSON(CFG.meUrl).then(function (me) {
          if (me && me.logged_in) {
            CFG.loggedIn = true;
            CFG.email = me.email || CFG.email;
            CFG.firstName = me.first_name || CFG.firstName;
            syncChatAuthState(me.email || CFG.email || "");
            setHiddenPrechatFields();
            sendIdentityToken();
          } else if (me) {
            syncChatAuthState("guest");
            if (CFG.loggedIn) { resetMessagingOnLogout(); }
            CFG.loggedIn = false;
            CFG.email = "";
            CFG.firstName = "";
          }
        }).catch(function () {});
      }

      function syncChatAuthState(state) {
        try {
          var last = localStorage.getItem("kwitko_chat_auth_state");
          if (messagingReady && last !== state) { resetMessagingOnLogout(); }
          localStorage.setItem("kwitko_chat_auth_state", state);
        } catch (e) {}
      }

      function sendIdentityToken() {
        if (!CFG.loggedIn || !CFG.email) return;
        fetchJSON(CFG.jwtUrl).then(function (res) {
          if (
            res && res.jwt &&
            window.embeddedservice_bootstrap &&
            embeddedservice_bootstrap.userVerificationAPI &&
            typeof embeddedservice_bootstrap.userVerificationAPI.setIdentityToken === "function"
          ) {
            embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
              identityTokenType: "JWT",
              identityToken: res.jwt
            });
          }
        }).catch(function () {});
      }

      function pollIdentify() {
        var t = token();
        if (!t || !CFG.identifyUrl) return;
        fetchJSON(CFG.identifyUrl + "?token=" + encodeURIComponent(t)).then(function (q) {
          if (!q || !q.email) return;
          fireDataCloudIdentify(q.email, q.firstName || "", "");
          fetch(CFG.identifyUrl + "?token=" + encodeURIComponent(t), {
            method: "DELETE",
            credentials: "include",
            headers: { "X-WP-Nonce": CFG.nonce || "" }
          }).catch(function () {});
        }).catch(function () {});
      }

      function ensureLoginStyles() {
        if (document.getElementById("kwitko-login-overlay-css")) return;
        var css = document.createElement("style");
        css.id = "kwitko-login-overlay-css";
        css.textContent =
          "#kwitko-login-overlay{position:fixed;inset:0;z-index:2147483000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center}" +
          "#kwitko-login-modal{width:min(460px,92vw);height:min(680px,90vh);background:#fff;border-radius:12px;overflow:hidden;display:flex;flex-direction:column;box-shadow:0 20px 60px rgba(0,0,0,.35)}" +
          "#kwitko-login-head{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;background:#3a2a1a;color:#fff;font:600 15px/1 system-ui,Arial,sans-serif}" +
          "#kwitko-login-close{background:transparent;border:0;color:#fff;font-size:24px;line-height:1;cursor:pointer}" +
          "#kwitko-login-frame{border:0;width:100%;height:100%;flex:1}";
        document.head.appendChild(css);
      }

      function stripLoginQuery() {
        try {
          var url = new URL(location.href);
          if (url.searchParams.has("kwitko_login")) {
            url.searchParams.delete("kwitko_login");
            history.replaceState(null, "", url.pathname + url.search + url.hash);
          }
        } catch (e) {}
      }

      function openLoginModal() {
        if (CFG.loggedIn && CFG.email) {
          stripLoginQuery();
          setHiddenPrechatFields();
          return;
        }
        if (document.getElementById("kwitko-login-overlay")) return;
        ensureLoginStyles();
        var overlay = document.createElement("div");
        overlay.id = "kwitko-login-overlay";
        overlay.innerHTML =
          '<div id="kwitko-login-modal" role="dialog" aria-modal="true" aria-label="Sign in">' +
          '<div id="kwitko-login-head"><span>Sign in to Kwitko Coffee</span>' +
          '<button id="kwitko-login-close" type="button" aria-label="Close">&times;</button></div>' +
          '<iframe id="kwitko-login-frame" src="' + CFG.loginUrl + '" title="Sign in"></iframe>' +
          "</div>";
        document.body.appendChild(overlay);
        document.getElementById("kwitko-login-close").onclick = function () { overlay.remove(); };
        overlay.addEventListener("click", function (e) {
          if (e.target === overlay) overlay.remove();
        });

        var frame = document.getElementById("kwitko-login-frame");
        var firstLoad = true;
        frame.addEventListener("load", function () {
          try {
            var doc = frame.contentDocument;
            var loggedIn = doc && (
              doc.querySelector(".woocommerce-MyAccount-navigation") ||
              /customer-logout|Log out|Dashboard/i.test(doc.body.innerHTML)
            );
            if (loggedIn && !firstLoad) {
              stripLoginQuery();
              location.reload();
              return;
            }
          } catch (e) {}
          firstLoad = false;
        });

        overlay._poll = setInterval(function () {
          refreshMe().then(function () {
            if (CFG.loggedIn && CFG.email) {
              clearInterval(overlay._poll);
              stripLoginQuery();
              location.reload();
            }
          });
        }, 2500);
      }

      function maybeOpenLoginFromUrl() {
        try {
          var q = new URLSearchParams(location.search);
          if (q.get("kwitko_login") === "1" || location.hash === "#kwitko-login") {
            openLoginModal();
          }
        } catch (e) {}
      }

      window.kwitkoOpenLogin = openLoginModal;
      window.addEventListener("message", function (e) {
        if (e && e.origin === location.origin && e.data && e.data.kwitko === "open-login") {
          openLoginModal();
        }
      });
      window.addEventListener("onEmbeddedMessagingReady", function () {
        messagingReady = true;
        ensureFreshConversationForIdentity();
        setHiddenPrechatFields();
        [0, 250, 1000, 3000, 6000].forEach(function (delay) {
          setTimeout(function () {
            setHiddenPrechatFields();
            refreshMe();
          }, delay);
        });
      });
      window.addEventListener("onEmbeddedMessagingIdentityTokenExpired", sendIdentityToken);

      setTimeout(maybeOpenLoginFromUrl, 0);
      setTimeout(maybeOpenLoginFromUrl, 1200);
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", maybeOpenLoginFromUrl);
      } else {
        maybeOpenLoginFromUrl();
      }
      refreshMe();
      setInterval(pollIdentify, 5000);
      setInterval(refreshMe, 30000);
      pollIdentify();
    })();
    </script>
    <?php
}, 5);
