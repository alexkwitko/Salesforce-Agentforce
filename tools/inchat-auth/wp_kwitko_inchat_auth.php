<?php
/**
 * Kwitko In-Chat Auth + Zero-Click Cart bridge (WordPress / WPCode snippet)
 * -------------------------------------------------------------------------
 * Install: WPCode -> Add Snippet -> PHP Snippet -> paste this -> "Run Everywhere" -> Activate.
 *
 * PREREQUISITE (one time): add your JWT private key to wp-config.php (NOT in this snippet, keep it secret):
 *     define('KWITKO_JWT_PRIVATE_KEY', "paste the JWT signing private key string from wp-config only");
 *     define('KWITKO_JWT_ISS', 'kwitko-coffee-store');   // MUST match the issuer you set in Salesforce keyset
 *     define('KWITKO_JWT_KID', 'kwitko-key-1');          // MUST match the kid you set in Salesforce keyset
 *
 * Provides:
 *   GET  /wp-json/kwitko/v1/me        -> { logged_in, email, first_name }   (current browser session)
 *   GET  /wp-json/kwitko/v1/jwt       -> { jwt }   signed RS256 identity token for the logged-in user
 *   GET  /wp-json/kwitko/v1/cart      -> { items:[wooId,...], coupon }  pending zero-click cart for a token (Phase 2)
 *   POST /wp-json/kwitko/v1/cart      -> queue a pending cart   (called by Salesforce, HMAC-signed)  (Phase 2)
 *   DELETE /wp-json/kwitko/v1/cart    -> clear a consumed pending cart (called by the browser)        (Phase 2)
 */

if (!defined('ABSPATH')) { exit; }

/* ----------------------------- JWT (RS256) ----------------------------- */
function kwitko_b64url($data) {
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function kwitko_mint_jwt($email, $first_name = '') {
    if (!defined('KWITKO_JWT_PRIVATE_KEY')) { return new WP_Error('no_key', 'JWT key not configured', array('status' => 500)); }
    $iss = defined('KWITKO_JWT_ISS') ? KWITKO_JWT_ISS : 'kwitko-coffee-store';
    $kid = defined('KWITKO_JWT_KID') ? KWITKO_JWT_KID : 'kwitko-key-1';
    $now = time();
    $header  = array('alg' => 'RS256', 'typ' => 'JWT', 'kid' => $kid);
    $payload = array(
        'sub'        => strtolower($email),   // Salesforce maps this to the verified Messaging end user
        'iss'        => $iss,
        'iat'        => $now,
        'exp'        => $now + 3600,          // 1 hour
        'email'      => strtolower($email),
        'first_name' => $first_name,
    );
    $signing_input = kwitko_b64url(wp_json_encode($header)) . '.' . kwitko_b64url(wp_json_encode($payload));
    $sig = '';
    $ok = openssl_sign($signing_input, $sig, KWITKO_JWT_PRIVATE_KEY, OPENSSL_ALGO_SHA256);
    if (!$ok) { return new WP_Error('sign_failed', 'Could not sign JWT', array('status' => 500)); }
    return $signing_input . '.' . kwitko_b64url($sig);
}

/* ----------------------------- REST routes ----------------------------- */
add_action('rest_api_init', function () {

    // Who is the current browser session?
    register_rest_route('kwitko/v1', '/me', array(
        'methods'  => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function () {
            if (is_user_logged_in()) {
                $u = wp_get_current_user();
                return array(
                    'logged_in'  => true,
                    'email'      => $u->user_email,
                    'first_name' => $u->first_name ? $u->first_name : $u->display_name,
                );
            }
            return array('logged_in' => false);
        },
    ));

    // Mint an identity JWT for the logged-in user (used to verify the chat session).
    register_rest_route('kwitko/v1', '/jwt', array(
        'methods'  => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function () {
            if (!is_user_logged_in()) {
                return new WP_Error('not_logged_in', 'Sign in first.', array('status' => 401));
            }
            $u = wp_get_current_user();
            $jwt = kwitko_mint_jwt($u->user_email, $u->first_name);
            if (is_wp_error($jwt)) { return $jwt; }
            return array(
                'jwt'        => $jwt,
                'email'      => $u->user_email,
                'first_name' => $u->first_name ? $u->first_name : $u->display_name,
            );
        },
    ));

    /* ---- Phase 2: zero-click cart queue (token-keyed, stored in a WP transient) ---- */
    register_rest_route('kwitko/v1', '/cart', array(
        array(
            'methods'  => 'GET',                       // browser polls for pending adds
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if (!$token) { return array('items' => array(), 'coupon' => ''); }
                $data = get_transient('kwitko_cart_' . $token);
                return $data ? $data : array('items' => array(), 'coupon' => '');
            },
        ),
        array(
            'methods'  => 'POST',                      // Salesforce queues a pending cart (HMAC-signed)
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $raw = $req->get_body();
                $sig = $req->get_header('X-Kwitko-Signature');
                $secret = defined('KWITKO_WHK_SECRET') ? KWITKO_WHK_SECRET : '';
                if ($secret) {
                    $calc = base64_encode(hash_hmac('sha256', $raw, $secret, true));
                    if (!hash_equals($calc, (string) $sig)) {
                        return new WP_Error('bad_sig', 'Invalid signature', array('status' => 401));
                    }
                }
                $body  = json_decode($raw, true);
                $token = isset($body['token']) ? sanitize_text_field($body['token']) : '';
                if (!$token) { return new WP_Error('no_token', 'token required', array('status' => 400)); }
                $payload = array(
                    'items'  => isset($body['items']) ? array_map('intval', (array) $body['items']) : array(),
                    'coupon' => isset($body['coupon']) ? sanitize_text_field($body['coupon']) : '',
                );
                set_transient('kwitko_cart_' . $token, $payload, 15 * MINUTE_IN_SECONDS);
                return array('ok' => true);
            },
        ),
        array(
            'methods'  => 'DELETE',                     // browser clears after consuming
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if ($token) { delete_transient('kwitko_cart_' . $token); }
                return array('ok' => true);
            },
        ),
    ));
});

/* ----------------------------- Front-end assets ----------------------------- */
add_action('wp_footer', function () {
    // Load the controller (modal + verification + cart poller).
    // Upload both assets to wp-content/uploads/kwitko/ so the PHP snippet is the
    // only WPCode snippet required for identity, cart token, and login modal glue.
    ?>
    <link rel="stylesheet" href="<?php echo esc_url(content_url('uploads/kwitko/kwitko_chat_controller.css')); ?>">
    <script>
      window.KWITKO_AUTH = {
        meUrl:   '<?php echo esc_url_raw(rest_url('kwitko/v1/me')); ?>',
        jwtUrl:  '<?php echo esc_url_raw(rest_url('kwitko/v1/jwt')); ?>',
        cartUrl: '<?php echo esc_url_raw(rest_url('kwitko/v1/cart')); ?>',
        loginUrl:'<?php echo esc_url(home_url('/my-account-2/')); ?>',
        storeApi:'<?php echo esc_url_raw(rest_url('wc/store/v1')); ?>',
        nonce:   '<?php echo esc_attr(wp_create_nonce('wp_rest')); ?>',
        loggedIn: <?php echo is_user_logged_in() ? 'true' : 'false'; ?>,
        email:   '<?php echo is_user_logged_in() ? esc_js(wp_get_current_user()->user_email) : ''; ?>',
        firstName:'<?php echo is_user_logged_in() ? esc_js(wp_get_current_user()->first_name ? wp_get_current_user()->first_name : wp_get_current_user()->display_name) : ''; ?>'
      };
    </script>
    <script src="<?php echo esc_url(content_url('uploads/kwitko/kwitko_chat_controller.js')); ?>" defer></script>
    <?php
}, 5);
