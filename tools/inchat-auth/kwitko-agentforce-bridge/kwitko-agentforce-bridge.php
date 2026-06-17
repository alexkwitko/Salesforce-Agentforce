<?php
/**
 * Plugin Name: Kwitko Agentforce Bridge
 * Description: Provides WooCommerce session identity, Agentforce hidden pre-chat fields, and zero-click cart bridge for Kwitko Coffee.
 * Version: 20260615.1
 * Author: Kwitko
 */

if (!defined('ABSPATH')) { exit; }

define('KWITKO_AGENTFORCE_BRIDGE_VERSION', '20260615.1');
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
                if (!$token) { return array('items' => array(), 'coupon' => '', 'clear' => false); }
                $data = get_transient('kwitko_cart_' . $token);
                return $data ? $data : array('items' => array(), 'coupon' => '', 'clear' => false);
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
                    'clear' => !empty($body['clear']),
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
                $secret = defined('KWITKO_WHK_SECRET') ? KWITKO_WHK_SECRET : '';
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

    register_rest_route('kwitko/v1', '/verification-code-email', array(
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
            $to_email = isset($body['to_email']) ? sanitize_email($body['to_email']) : '';
            $code = isset($body['code']) ? sanitize_text_field($body['code']) : '';
            $expires = isset($body['expires_minutes']) ? absint($body['expires_minutes']) : 10;
            if (!$to_email || !is_email($to_email) || !preg_match('/^\d{6}$/', $code)) {
                return new WP_Error('missing', 'email and 6-digit code required', array('status' => 400));
            }
            if ($expires <= 0) { $expires = 10; }
            $subject = 'Your Kwitko Coffee verification code';
            $message = '<p>Hi,</p><p>Your Kwitko Coffee verification code is:</p>'
                . '<p style="font-size:24px;font-weight:bold;letter-spacing:3px">' . esc_html($code) . '</p>'
                . '<p>It expires in ' . esc_html((string) $expires) . ' minutes. If you did not request this, ignore this email.</p>';
            if (function_exists('WC') && WC() && WC()->mailer()) {
                $mailer = WC()->mailer();
                $wrapped = $mailer->wrap_message($subject, $message);
                $sent = $mailer->send($to_email, $subject, $wrapped, array('Content-Type: text/html; charset=UTF-8'));
            } else {
                $sent = wp_mail($to_email, $subject, $message, array('Content-Type: text/html; charset=UTF-8'));
            }
            if (!$sent) {
                return new WP_Error('mail_failed', 'WordPress mailer failed', array('status' => 500));
            }
            return array('ok' => true, 'message' => 'verification email sent');
        },
    ));
});

function kwitko_bridge_cart_ids($raw) {
    $ids = array();
    foreach (explode(',', (string) $raw) as $part) {
        $id = absint(trim($part));
        if ($id > 0 && !in_array($id, $ids, true)) {
            $ids[] = $id;
        }
        if (count($ids) >= 10) { break; }
    }
    return $ids;
}

add_action('template_redirect', function () {
    if (is_admin() || wp_doing_ajax() || wp_is_json_request()) { return; }
    if (empty($_GET['kc_add'])) { return; }
    if (!function_exists('WC')) { return; }
    if (function_exists('wc_load_cart')) { wc_load_cart(); }
    if (!WC() || !WC()->cart) { return; }

    $ids = kwitko_bridge_cart_ids(wp_unslash($_GET['kc_add']));
    if (empty($ids)) { return; }

    $clear = !empty($_GET['kc_clear']) && in_array(strtolower(sanitize_text_field(wp_unslash($_GET['kc_clear']))), array('1', 'true', 'yes', 'replace'), true);
    if ($clear) {
        WC()->cart->empty_cart();
    }

    $added = 0;
    foreach ($ids as $product_id) {
        $key = WC()->cart->add_to_cart($product_id, 1);
        if ($key) { $added++; }
    }

    if (!empty($_GET['kc_coupon'])) {
        $coupon = wc_format_coupon_code(sanitize_text_field(wp_unslash($_GET['kc_coupon'])));
        if ($coupon && !WC()->cart->has_discount($coupon)) {
            WC()->cart->apply_coupon($coupon);
        }
    }

    if ($added > 0 && function_exists('wc_add_notice')) {
        wc_add_notice(
            $clear
                ? __('Your recommendation was added to a fresh cart.', 'kwitko')
                : __('Your recommendation was added to your cart.', 'kwitko'),
            'success'
        );
    }

    wp_safe_redirect(function_exists('wc_get_cart_url') ? wc_get_cart_url() : home_url('/cart-2/'));
    exit;
}, 0);

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
        identifyUrl: '<?php echo esc_url_raw(rest_url('kwitko/v1/identify')); ?>',
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
