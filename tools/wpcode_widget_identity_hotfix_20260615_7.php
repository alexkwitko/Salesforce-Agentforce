<?php
/**
 * Kwitko Widget Identity Hotfix 20260615.7
 *
 * WPCode PHP snippet, Run Everywhere, Active.
 * Additive hotfix while the larger Data Cloud SDK snippet remains on 20260615.6.
 */

if ( ! defined( 'ABSPATH' ) ) { exit; }

if ( ! defined( 'KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION' ) ) {
	define( 'KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION', '20260615.7' );
}

add_action( 'rest_api_init', function () {
	register_rest_route( 'kwitko/v1', '/me', array(
		'methods'             => 'GET',
		'permission_callback' => '__return_true',
		'callback'            => function () {
			if ( is_user_logged_in() ) {
				$u = wp_get_current_user();
				return array(
					'logged_in'      => true,
					'email'          => $u->user_email,
					'first_name'     => $u->first_name ? $u->first_name : $u->display_name,
					'bridge_version' => KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION,
				);
			}
			return array(
				'logged_in'      => false,
				'bridge_version' => KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION,
			);
		},
	), true );
}, 999 );

add_action( 'wp_footer', function () {
	if ( is_admin() ) { return; }
	?>
	<script id="kwitko-widget-identity-hotfix-20260615-7">
	(function () {
	  "use strict";
	  var VERSION = "<?php echo esc_js( KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION ); ?>";
	  if (window.KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION === VERSION) return;
	  window.KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION = VERSION;

	  function auth() { return window.KWITKO_AUTH || {}; }
	  function identityOf(a) {
	    return a && a.loggedIn && a.email ? "user:" + String(a.email).toLowerCase() : "guest";
	  }
	  function fetchJSON(url) {
	    return fetch(url, {
	      credentials: "include",
	      headers: { "X-WP-Nonce": auth().nonce || "" }
	    }).then(function (r) { return r.ok ? r.json() : null; });
	  }
	  function clearChat(removeComponents) {
	    try {
	      var b = window.embeddedservice_bootstrap;
	      if (!b) return false;
	      if (b.utilAPI && typeof b.utilAPI.clearSession === "function") {
	        b.utilAPI.clearSession({ shouldEndSession: true });
	      } else if (typeof b.clearSession === "function") {
	        b.clearSession({ shouldEndSession: true });
	      }
	      if (removeComponents && b.utilAPI && typeof b.utilAPI.removeAllComponents === "function") {
	        b.utilAPI.removeAllComponents();
	      }
	      if (b.userVerificationAPI && typeof b.userVerificationAPI.clearSession === "function") {
	        b.userVerificationAPI.clearSession({ shouldEndSession: true });
	      }
	      return true;
	    } catch (e) {
	      return false;
	    }
	  }
	  function dcIdentify(a) {
	    try {
	      if (!a || !a.loggedIn || !a.email) return;
	      var f = typeof window.kwitkoDataCloudIdentify === "function"
	        ? window.kwitkoDataCloudIdentify
	        : (typeof window.kwitkoIdentify === "function" ? window.kwitkoIdentify : null);
	      if (f && window.__kwitkoIdentifyDone !== a.email) {
	        f(a.email, a.firstName || "", "");
	        window.__kwitkoIdentifyDone = a.email;
	      }
	    } catch (e) {}
	  }
	  function dcReset() {
	    try { window.__kwitkoIdentifyDone = null; } catch (e) {}
	    try {
	      if (typeof window.kwitkoDataCloudReset === "function") {
	        window.kwitkoDataCloudReset();
	      } else if (window.SalesforceInteractions && typeof window.SalesforceInteractions.reset === "function") {
	        window.SalesforceInteractions.reset();
	      }
	    } catch (e) {}
	  }
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
	  function setHidden(a) {
	    a = a || auth();
	    if (!a.loggedIn || !a.email) return false;
	    dcIdentify(a);
	    try {
	      if (!window.embeddedservice_bootstrap || !embeddedservice_bootstrap.prechatAPI) return false;
	      embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
	        "Kwitko_Logged_In_Email__c": a.email,
	        "Kwitko_Logged_In_First_Name__c": a.firstName || ""
	      });
	      var cartToken = token();
	      if (cartToken) {
	        embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
	          "Kwitko_Cart_Token__c": cartToken
	        });
	      }
	      return true;
	    } catch (e) {
	      return false;
	    }
	  }
	  function sendJwt(a) {
	    a = a || auth();
	    if (!a.loggedIn || !a.email || !a.jwtUrl) return;
	    fetchJSON(a.jwtUrl).then(function (res) {
	      try {
	        if (res && res.jwt && window.embeddedservice_bootstrap &&
	            embeddedservice_bootstrap.userVerificationAPI &&
	            typeof embeddedservice_bootstrap.userVerificationAPI.setIdentityToken === "function") {
	          embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
	            identityTokenType: "JWT",
	            identityToken: res.jwt
	          });
	        }
	      } catch (e) {}
	    }).catch(function () {});
	  }
	  function reconcile(a) {
	    a = a || auth();
	    var current = identityOf(a);
	    try {
	      var key = "kwitko_widget_identity_hotfix";
	      var previous = localStorage.getItem(key);
	      if (previous !== current) {
	        if (previous !== null || current !== "guest") {
	          if (current === "guest") dcReset();
	          clearChat(false);
	        }
	        localStorage.setItem(key, current);
	      }
	    } catch (e) {}
	    setHidden(a);
	    sendJwt(a);
	  }
	  function refresh() {
	    var a = auth();
	    if (!a.meUrl) {
	      reconcile(a);
	      return Promise.resolve(a);
	    }
	    return fetchJSON(a.meUrl).then(function (me) {
	      if (me && me.logged_in) {
	        window.KWITKO_AUTH = Object.assign({}, auth(), {
	          loggedIn: true,
	          email: me.email || "",
	          firstName: me.first_name || ""
	        });
	      } else if (me) {
	        window.KWITKO_AUTH = Object.assign({}, auth(), {
	          loggedIn: false,
	          email: "",
	          firstName: ""
	        });
	      }
	      reconcile(auth());
	      return auth();
	    }).catch(function () {
	      reconcile(auth());
	      return auth();
	    });
	  }

	  window.addEventListener("onEmbeddedMessagingReady", function () {
	    refresh();
	    [0, 150, 500, 1500, 3000, 6000].forEach(function (delay) {
	      setTimeout(refresh, delay);
	    });
	  });
	  window.addEventListener("onEmbeddedMessagingIdentityTokenExpired", function () {
	    sendJwt(auth());
	  });
	  refresh();
	  setInterval(refresh, 15000);
	})();
	</script>
	<?php
}, 9999 );
