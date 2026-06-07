<?php
/**
 * Kwitko chat emergency preflight (WordPress mu-plugin).
 *
 * Runs before the Salesforce Embedded Messaging bootstrap. It clears stale
 * Salesforce web-storage state once per browser session, because stale JWT
 * conversation storage can leave the launcher spinning on "Loading...".
 */

if (!defined('ABSPATH')) { exit; }

add_action('wp_footer', 'kwitko_chat_emergency_preflight', 0);

function kwitko_chat_emergency_preflight() {
    ?>
    <style id="kwitko-hide-legacy-signin-button">
      #kwitko-signin-btn{display:none!important;visibility:hidden!important;pointer-events:none!important}
    </style>
    <script id="kwitko-chat-emergency-preflight">
      (function () {
        'use strict';
        var ORG_ID = '00DXX0000000000';
        var RESET_FLAG = 'kwitko_sf_chat_storage_reset_20260607_v2';

        function getStorage(name) {
          try {
            var s = window[name];
            var test = '__kwitko_storage_test__';
            s.setItem(test, '1');
            s.removeItem(test);
            return s;
          } catch (e) {
            return null;
          }
        }

        function shouldRemoveKey(key) {
          return key === ORG_ID + '_WEB_STORAGE' ||
            /embedded(service|messaging)|salesforce|scrt|ESW/i.test(key);
        }

        function clearSalesforceChatStorage(reason) {
          ['localStorage', 'sessionStorage'].forEach(function (storeName) {
            var store = getStorage(storeName);
            if (!store) return;
            var keys = [];
            for (var i = 0; i < store.length; i += 1) {
              var key = store.key(i);
              if (key && shouldRemoveKey(key)) keys.push(key);
            }
            keys.forEach(function (key) { try { store.removeItem(key); } catch (e) {} });
          });
          try { console.warn('[Kwitko chat] Cleared stale Salesforce chat storage:', reason); } catch (e) {}
        }

        var session = getStorage('sessionStorage');
        if (!session || session.getItem(RESET_FLAG) !== '1') {
          clearSalesforceChatStorage('pre-bootstrap');
          if (session) session.setItem(RESET_FLAG, '1');
        }

        document.addEventListener('click', function (event) {
          var target = event.target && event.target.closest && event.target.closest('#embeddedMessagingConversationButton');
          if (!target) return;
          setTimeout(function () {
            var btn = document.getElementById('embeddedMessagingConversationButton');
            if (btn && /Loading/i.test(btn.textContent || '')) {
              clearSalesforceChatStorage('launcher-stuck-loading');
              location.reload();
            }
          }, 9000);
        }, true);
      })();
    </script>
    <?php
}
