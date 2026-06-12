/*
 * Kwitko Chat Controller — storefront-side hub for:
 *   (1) In-chat sign-in modal (embeds the REAL /my-account login) + JWT user verification
 *   (2) Zero-click cart (Option C): poll Salesforce-queued cart, add live via WooCommerce Store API
 *       with automatic A+B fallback (redirect button) if the Store API add fails.
 *
 * Install: upload this file to wp-content/uploads/kwitko/ and load it from the WPCode PHP snippet.
 * Requires window.KWITKO_AUTH (printed by wp_kwitko_inchat_auth.php).
 */
(function () {
  "use strict";
  var CFG = window.KWITKO_AUTH || {};
  CFG.loginUrl = CFG.loginUrl || "/my-account-2/";
  window.KWITKO_CHAT_CONTROLLER_VERSION = "20260607.7";
  var POLL_MS = 3000;
  var verified = false;
  var allowedPrechatFields = null;
  var allowedPrechatFieldsPromise = null;

  /* ---------- inject styles (no separate CSS file needed) ---------- */
  (function injectCSS() {
    if (document.getElementById("kwitko-chat-css")) return;
    var css =
      "#kwitko-login-overlay{position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center}" +
      "#kwitko-login-modal{width:min(440px,92vw);height:min(640px,90vh);background:#fff;border-radius:14px;overflow:hidden;display:flex;flex-direction:column;box-shadow:0 20px 60px rgba(0,0,0,.4)}" +
      "#kwitko-login-head{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;background:#3a2a1a;color:#fff;font:600 15px/1 system-ui,Arial,sans-serif}" +
      "#kwitko-login-close{background:transparent;border:0;color:#fff;font-size:24px;line-height:1;cursor:pointer}" +
      "#kwitko-login-frame{border:0;width:100%;height:100%;flex:1}" +
      ".kwitko-toast{position:fixed;left:50%;bottom:88px;transform:translateX(-50%) translateY(12px);background:#1f7a3d;color:#fff;padding:10px 18px;border-radius:22px;font:600 14px/1.2 system-ui,Arial,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.3);opacity:0;transition:opacity .3s,transform .3s;z-index:10001;max-width:90vw;text-align:center}" +
      ".kwitko-toast.show{opacity:1;transform:translateX(-50%) translateY(0)}";
    var s = document.createElement("style");
    s.id = "kwitko-chat-css";
    s.textContent = css;
    document.head.appendChild(s);
  })();

  /* ---------- session token (bridge key for the cart poller) ---------- */
  function token() {
    var t = localStorage.getItem("kwitko_token");
    if (!t) {
      t =
        "kc-" +
        Date.now().toString(36) +
        "-" +
        Math.random().toString(36).slice(2, 10);
      localStorage.setItem("kwitko_token", t);
    }
    return t;
  }

  /* ---------- Embedded Messaging hooks ---------- */
  window.addEventListener("onEmbeddedMessagingReady", function () {
    syncIdentity("ready");
  });

  // If the identity token expires mid-session, silently re-issue it.
  window.addEventListener(
    "onEmbeddedMessagingIdentityTokenExpired",
    function () {
      syncIdentity("expired");
    }
  );

  function syncIdentity(reason) {
    setHiddenPrechatFields();
    refreshIdentity();
    [250, 1000, 3000, 6000].forEach(function (delay) {
      setTimeout(function () {
        setHiddenPrechatFields();
        refreshIdentity();
      }, delay);
    });
  }

  function refreshIdentity() {
    fetchJSON(CFG.meUrl)
      .then(function (me) {
        if (me && me.logged_in) {
          CFG.loggedIn = true;
          CFG.email = me.email || CFG.email;
          CFG.firstName = me.first_name || CFG.firstName;
          setHiddenPrechatFields();
          sendIdentity();
        } else {
          CFG.loggedIn = false;
        }
      })
      .catch(function () {});
  }

  function sendIdentity() {
    return fetchJSON(CFG.jwtUrl)
      .then(function (res) {
        if (res && res.email) CFG.email = res.email;
        if (res && res.first_name) CFG.firstName = res.first_name;
        if (
          res &&
          res.jwt &&
          window.embeddedservice_bootstrap &&
          embeddedservice_bootstrap.userVerificationAPI
        ) {
          embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
            identityTokenType: "JWT",
            identityToken: res.jwt
          });
          verified = true;
          setHiddenPrechatFields();
          toast("✓ Signed in — your chat is now verified.");
        }
      })
      .catch(function () {});
  }

  function setHiddenPrechatFields() {
    if (
      !window.embeddedservice_bootstrap ||
      !embeddedservice_bootstrap.prechatAPI
    ) {
      return;
    }

    getAllowedPrechatFields()
      .then(function (allowed) {
        var fields = {};
        if (allowed.Logged_In_Email && CFG.loggedIn && CFG.email) {
          fields[allowed.Logged_In_Email] = CFG.email;
        }
        if (allowed.Logged_In_First_Name && CFG.loggedIn && CFG.firstName) {
          fields[allowed.Logged_In_First_Name] = CFG.firstName;
        }
        if (allowed.Kwitko_Cart_Token) {
          fields[allowed.Kwitko_Cart_Token] = token();
        }
        if (Object.keys(fields).length) {
          embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields(fields);
        }
      })
      .catch(function () {
        /* hidden prechat is optional; do not block chat startup */
      });
  }

  function getAllowedPrechatFields() {
    if (allowedPrechatFields) return Promise.resolve(allowedPrechatFields);
    if (allowedPrechatFieldsPromise) return allowedPrechatFieldsPromise;
    if (!CFG.embeddedConfigUrl) {
      allowedPrechatFields = {};
      return Promise.resolve(allowedPrechatFields);
    }

    allowedPrechatFieldsPromise = fetchJSON(CFG.embeddedConfigUrl)
      .then(function (cfg) {
        var allowed = {};
        var aliases = {
          Logged_In_Email: [
            "Logged_In_Email",
            "Kwitko_Logged_In_Email__c",
            "loggedInEmail"
          ],
          Logged_In_First_Name: [
            "Logged_In_First_Name",
            "Kwitko_Logged_In_First_Name__c",
            "loggedInFirstName"
          ],
          Kwitko_Cart_Token: [
            "Kwitko_Cart_Token",
            "Kwitko_Cart_Token__c",
            "cartToken"
          ]
        };
        var canonicalByAlias = {};
        Object.keys(aliases).forEach(function (canonical) {
          aliases[canonical].forEach(function (name) {
            canonicalByAlias[name] = canonical;
          });
        });

        function visit(node) {
          if (!node) return;
          if (Array.isArray(node)) {
            node.forEach(visit);
            return;
          }
          if (typeof node !== "object") return;
          [
            node.name,
            node.formField,
            node.fieldName,
            node.developerName,
            node.externalParameterName
          ].forEach(function (name) {
            if (canonicalByAlias[name]) allowed[canonicalByAlias[name]] = name;
          });
          Object.keys(node).forEach(function (key) {
            visit(node[key]);
          });
        }

        var forms =
          cfg && cfg.embeddedServiceConfig && cfg.embeddedServiceConfig.forms;
        visit(forms);
        allowedPrechatFields = allowed;
        return allowedPrechatFields;
      })
      .catch(function () {
        allowedPrechatFields = {};
        return allowedPrechatFields;
      });

    return allowedPrechatFieldsPromise;
  }

  /* ---------- Sign-in modal (embeds the real WooCommerce login) ---------- */
  function openLoginModal() {
    if (document.getElementById("kwitko-login-overlay")) return;
    var ov = document.createElement("div");
    ov.id = "kwitko-login-overlay";
    ov.innerHTML =
      '<div id="kwitko-login-modal" role="dialog" aria-modal="true" aria-label="Sign in">' +
      '<div id="kwitko-login-head"><span>Sign in to Kwitko Coffee</span>' +
      '<button id="kwitko-login-close" aria-label="Close">&times;</button></div>' +
      '<iframe id="kwitko-login-frame" src="' +
      CFG.loginUrl +
      '" title="Sign in"></iframe>' +
      "</div>";
    document.body.appendChild(ov);
    document.getElementById("kwitko-login-close").onclick = closeLoginModal;
    ov.addEventListener("click", function (e) {
      if (e.target === ov) closeLoginModal();
    });

    // Detect login via the same-origin account iframe. After WooCommerce login it redirects to the
    // account dashboard (shows the MyAccount nav / a logout link). On that post-login navigation we
    // reload the parent so WordPress issues a fresh AUTHENTICATED REST nonce; refreshIdentity() then
    // auto-verifies the chat on the reloaded page.
    var frame = document.getElementById("kwitko-login-frame");
    var firstLoad = true;
    frame.addEventListener("load", function () {
      try {
        var doc = frame.contentDocument;
        var loggedIn =
          doc &&
          (doc.querySelector(".woocommerce-MyAccount-navigation") ||
            /customer-logout|wp-admin\/profile|Log out/i.test(
              doc.body.innerHTML
            ));
        if (loggedIn && !firstLoad) {
          sessionStorage.setItem("kwitko_just_logged_in", "1");
          location.reload();
          return;
        }
      } catch (e) {
        /* cross-doc not ready */
      }
      firstLoad = false;
    });
    // Fallback poll (works when the REST nonce is still valid).
    ov._poll = setInterval(function () {
      fetchJSON(CFG.meUrl)
        .then(function (me) {
          if (me && me.logged_in) {
            clearInterval(ov._poll);
            sendIdentity().then(closeLoginModal);
          }
        })
        .catch(function () {});
    }, 2500);
  }

  function closeLoginModal() {
    var ov = document.getElementById("kwitko-login-overlay");
    if (!ov) return;
    if (ov._poll) clearInterval(ov._poll);
    ov.remove();
  }

  // No floating page-level sign-in button. The visible sign-in affordance belongs in chat.
  function maybeOpenLoginFromChatLink() {
    var q = new URLSearchParams(location.search);
    if (q.get("kwitko_login") === "1" || location.hash === "#kwitko-login") {
      openLoginModal();
    }
  }
  if (document.readyState !== "loading") maybeOpenLoginFromChatLink();
  else
    document.addEventListener("DOMContentLoaded", maybeOpenLoginFromChatLink);

  // Let trusted chat/page links request the modal: window.postMessage({kwitko:'open-login'})
  window.addEventListener("message", function (e) {
    if (
      e &&
      e.origin === location.origin &&
      e.data &&
      e.data.kwitko === "open-login"
    )
      openLoginModal();
  });

  /* ---------- Zero-click cart poller (Option C) + A/B fallback ---------- */
  setInterval(pollCart, POLL_MS);
  function pollCart() {
    fetchJSON(CFG.cartUrl + "?token=" + encodeURIComponent(token()))
      .then(function (q) {
        if (!q || !q.items || !q.items.length) return;
        addItemsLive(q.items, q.coupon).then(function (ok) {
          // Clear the queue either way so it isn't re-applied.
          fetch(CFG.cartUrl + "?token=" + encodeURIComponent(token()), {
            method: "DELETE"
          }).catch(function () {});
          if (ok) {
            refreshMiniCart();
            toast(
              "🛒 Added to your cart" +
                (q.coupon ? " with your discount" : "") +
                "."
            );
          } else {
            // Fallback A+B: send the shopper to the working add-to-cart URL.
            var url =
              location.origin +
              "/?kc_add=" +
              q.items.join(",") +
              (q.coupon ? "&kc_coupon=" + encodeURIComponent(q.coupon) : "");
            location.assign(url);
          }
        });
      })
      .catch(function () {});
  }

  // Add each product via the WooCommerce Store API (same-origin, uses the live cart session).
  function addItemsLive(items, coupon) {
    return getStoreNonce().then(function (nonce) {
      if (!nonce) return false;
      var chain = Promise.resolve(true);
      items.forEach(function (id) {
        chain = chain.then(function (okSoFar) {
          if (!okSoFar) return false;
          return fetch(CFG.storeApi + "/cart/add-item", {
            method: "POST",
            headers: { "Content-Type": "application/json", Nonce: nonce },
            credentials: "include",
            body: JSON.stringify({ id: parseInt(id, 10), quantity: 1 })
          })
            .then(function (r) {
              return r.ok;
            })
            .catch(function () {
              return false;
            });
        });
      });
      return chain.then(function (okSoFar) {
        if (okSoFar && coupon) {
          return fetch(CFG.storeApi + "/cart/apply-coupon", {
            method: "POST",
            headers: { "Content-Type": "application/json", Nonce: nonce },
            credentials: "include",
            body: JSON.stringify({ code: coupon })
          })
            .then(function () {
              return true;
            })
            .catch(function () {
              return true;
            }); // coupon failure is non-fatal
        }
        return okSoFar;
      });
    });
  }

  function getStoreNonce() {
    return fetch(CFG.storeApi + "/cart", { credentials: "include" })
      .then(function (r) {
        return r.headers.get("Nonce") || r.headers.get("X-WC-Store-API-Nonce");
      })
      .catch(function () {
        return null;
      });
  }

  function refreshMiniCart() {
    try {
      if (window.wp && wp.data && wp.data.dispatch) {
        wp.data.dispatch("wc/store/cart").invalidateResolutionForStore();
      }
    } catch (e) {}
    try {
      if (window.jQuery) jQuery(document.body).trigger("wc_fragment_refresh");
    } catch (e) {}
    document.body.dispatchEvent(
      new CustomEvent("wc-blocks_render_blocks_frontend")
    );
  }

  /* ---------- helpers ---------- */
  function fetchJSON(url) {
    var opts = {};
    var target;
    try {
      target = new URL(url, window.location.href);
    } catch (e) {
      target = null;
    }
    if (!target || target.origin === window.location.origin) {
      opts.credentials = "include";
      opts.headers = { "X-WP-Nonce": CFG.nonce || "" };
    }
    return fetch(url, opts).then(function (r) {
      return r.ok ? r.json() : null;
    });
  }
  function toast(msg) {
    var t = document.createElement("div");
    t.className = "kwitko-toast";
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(function () {
      t.classList.add("show");
    }, 10);
    setTimeout(function () {
      t.classList.remove("show");
      setTimeout(function () {
        t.remove();
      }, 300);
    }, 3500);
  }
})();
