<?php
/**
 * Plugin Name: Kwitko Agentforce Bridge
 * Description: Provides WooCommerce session identity, Agentforce hidden pre-chat fields, and zero-click cart bridge for Kwitko Coffee.
 * Version: 20260607.7
 * Author: Kwitko
 */

if (!defined('ABSPATH')) { exit; }

define('KWITKO_AGENTFORCE_BRIDGE_VERSION', '20260607.7');
define('KWITKO_EMBEDDED_CONFIG_URL', 'https://MYDOMAIN.develop.my.salesforce-scrt.com/embeddedservice/v1/embedded-service-config?orgId=00DXX0000000000&esConfigName=Kwitko_Web_Chat&language=en_US');

function kwitko_bridge_b64url($data) {
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function kwitko_bridge_mint_jwt($email, $first_name = '') {
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

    $signing_input = kwitko_bridge_b64url(wp_json_encode($header)) . '.' . kwitko_bridge_b64url(wp_json_encode($payload));
    $sig = '';
    $ok = openssl_sign($signing_input, $sig, KWITKO_JWT_PRIVATE_KEY, OPENSSL_ALGO_SHA256);
    if (!$ok) {
        return new WP_Error('sign_failed', 'Could not sign JWT', array('status' => 500));
    }

    return $signing_input . '.' . kwitko_bridge_b64url($sig);
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
                    'bridge_version' => KWITKO_AGENTFORCE_BRIDGE_VERSION,
                );
            }
            return array(
                'logged_in' => false,
                'bridge_version' => KWITKO_AGENTFORCE_BRIDGE_VERSION,
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
            $jwt = kwitko_bridge_mint_jwt($u->user_email, $u->first_name);
            if (is_wp_error($jwt)) { return $jwt; }
            return array(
                'jwt' => $jwt,
                'email' => $u->user_email,
                'first_name' => $u->first_name ? $u->first_name : $u->display_name,
                'bridge_version' => KWITKO_AGENTFORCE_BRIDGE_VERSION,
            );
        },
    ));

    register_rest_route('kwitko/v1', '/cart', array(
        array(
            'methods' => 'GET',
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if (!$token) { return array('items' => array(), 'coupon' => ''); }
                $data = get_transient('kwitko_cart_' . $token);
                return $data ? $data : array('items' => array(), 'coupon' => '');
            },
        ),
        array(
            'methods' => 'POST',
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
                $body = json_decode($raw, true);
                $token = isset($body['token']) ? sanitize_text_field($body['token']) : '';
                if (!$token) {
                    return new WP_Error('no_token', 'token required', array('status' => 400));
                }
                $payload = array(
                    'items' => isset($body['items']) ? array_map('intval', (array) $body['items']) : array(),
                    'coupon' => isset($body['coupon']) ? sanitize_text_field($body['coupon']) : '',
                );
                set_transient('kwitko_cart_' . $token, $payload, 15 * MINUTE_IN_SECONDS);
                return array('ok' => true);
            },
        ),
        array(
            'methods' => 'DELETE',
            'permission_callback' => '__return_true',
            'callback' => function ($req) {
                $token = sanitize_text_field($req->get_param('token'));
                if ($token) { delete_transient('kwitko_cart_' . $token); }
                return array('ok' => true);
            },
        ),
    ));
});

add_action('template_redirect', function () {
    if (is_admin() || wp_doing_ajax() || wp_is_json_request()) { return; }
    ob_start('kwitko_bridge_strip_legacy_chat_snippets');
}, 0);

function kwitko_bridge_strip_legacy_chat_snippets($html) {
    $patterns = array(
        '#<style[^>]+id=[\'"]kwitko-hide-legacy-signin-button[\'"][\s\S]*?</style>#i',
        '#<script[^>]+id=[\'"]kwitko-chat-emergency-preflight[\'"][\s\S]*?</script>#i',
        '#<script>\s*/\*[\s\S]*?Kwitko Chat Controller[\s\S]*?</script>#i',
        '#<!--\s*Kwitko cart glue:[\s\S]*?</script>#i',
        '#<link\b[^>]+href=[\'"][^\'"]*/uploads/kwitko/kwitko_chat_controller\.css[^\'"]*[\'"][^>]*>\s*#i',
        '#<script\b[^>]+src=[\'"][^\'"]*/uploads/kwitko/kwitko_chat_controller\.js[^\'"]*[\'"][^>]*>\s*</script>\s*#i',
    );
    $html = preg_replace($patterns, '', $html);

    return preg_replace_callback(
        '#<script\b(?![^>]*\bsrc=)[^>]*>[\s\S]*?</script>#i',
        function ($matches) {
            $script = $matches[0];
            if (
                strpos($script, 'window.KWITKO_AUTH') !== false &&
                strpos($script, 'embeddedConfigUrl') === false
            ) {
                return '';
            }
            return $script;
        },
        $html
    );
}

add_action('wp_footer', function () {
    $current_user = is_user_logged_in() ? wp_get_current_user() : null;
    $first_name = $current_user ? ($current_user->first_name ? $current_user->first_name : $current_user->display_name) : '';
    ?>
    <link rel="stylesheet" href="<?php echo esc_url(plugins_url('assets/kwitko_chat_controller.css', __FILE__) . '?v=' . KWITKO_AGENTFORCE_BRIDGE_VERSION); ?>">
    <script>
      window.KWITKO_AUTH = {
        meUrl: '<?php echo esc_url_raw(rest_url('kwitko/v1/me')); ?>',
        jwtUrl: '<?php echo esc_url_raw(rest_url('kwitko/v1/jwt')); ?>',
        cartUrl: '<?php echo esc_url_raw(rest_url('kwitko/v1/cart')); ?>',
        loginUrl: '<?php echo esc_url(home_url('/my-account-2/')); ?>',
        storeApi: '<?php echo esc_url_raw(rest_url('wc/store/v1')); ?>',
        embeddedConfigUrl: '<?php echo esc_url_raw(KWITKO_EMBEDDED_CONFIG_URL); ?>',
        nonce: '<?php echo esc_attr(wp_create_nonce('wp_rest')); ?>',
        loggedIn: <?php echo $current_user ? 'true' : 'false'; ?>,
        email: '<?php echo $current_user ? esc_js($current_user->user_email) : ''; ?>',
        firstName: '<?php echo esc_js($first_name); ?>',
        controllerVersion: '<?php echo esc_js(KWITKO_AGENTFORCE_BRIDGE_VERSION); ?>'
      };
    </script>
    <script src="<?php echo esc_url(plugins_url('assets/kwitko_chat_controller.js', __FILE__) . '?v=' . KWITKO_AGENTFORCE_BRIDGE_VERSION); ?>" defer></script>
    <?php
}, 5);
