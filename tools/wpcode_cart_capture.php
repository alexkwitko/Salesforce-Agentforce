<?php
/**
 * WPCode snippet: "Kwitko — Live Cart Capture → Salesforce"
 * Type: PHP Snippet | Auto-insert: Run everywhere | Priority: default
 *
 * Sends the shopper's current WooCommerce cart to the Salesforce public REST endpoint so the
 * abandoned-cart agent can recover it. Fires on cart changes and at checkout (when the email is
 * known). Server-side + HMAC-signed so the shared secret never reaches the browser.
 *
 * SETUP: paste your Salesforce Woo webhook secret into KWITKO_SF_SECRET below (same secret used by
 * the order webhook — the WC_WEBHOOK_SECRET value). Do not share it publicly.
 */

if ( ! defined( 'ABSPATH' ) ) { exit; }

define( 'KWITKO_SF_CART_URL', 'https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/woo/cart/' );
define( 'KWITKO_SF_SECRET', 'PASTE_YOUR_WC_WEBHOOK_SECRET_HERE' ); // <-- same secret as the order webhook

if ( ! function_exists( 'kwitko_sync_cart_to_sf' ) ) {

    function kwitko_sync_cart_to_sf( $email_override = '' ) {
        if ( is_admin() || ! function_exists( 'WC' ) ) { return; }
        $cart = WC()->cart;
        if ( ! $cart || $cart->is_empty() ) { return; }

        // --- identify the shopper ---
        $email = '';
        $first = ''; $last = ''; $consent = false;
        if ( is_user_logged_in() ) {
            $u = wp_get_current_user();
            $email = $u->user_email;
            $first = get_user_meta( $u->ID, 'first_name', true );
            $last  = get_user_meta( $u->ID, 'last_name', true );
            $consent = ( get_user_meta( $u->ID, 'marketing_consent', true ) === 'yes' );
        }
        if ( empty( $email ) && ! empty( $email_override ) ) { $email = sanitize_email( $email_override ); }
        // also try the checkout session billing email (guest entering email at checkout)
        if ( empty( $email ) && WC()->customer ) {
            $be = WC()->customer->get_billing_email();
            if ( ! empty( $be ) ) { $email = $be; $first = WC()->customer->get_billing_first_name(); $last = WC()->customer->get_billing_last_name(); }
        }

        // --- build the items ---
        $items = array();
        foreach ( $cart->get_cart() as $ci ) {
            $p = $ci['data'];
            if ( ! $p ) { continue; }
            $items[] = array(
                'product_id' => $p->get_id(),
                'sku'        => $p->get_sku(),
                'name'       => $p->get_name(),
                'quantity'   => (int) $ci['quantity'],
                'price'      => (float) $p->get_price(),
            );
        }
        if ( empty( $items ) ) { return; }

        $payload = array(
            'cart_id'    => WC()->session ? WC()->session->get_customer_id() : ( $email ? 'email:' . $email : '' ),
            'email'      => $email,
            'first_name' => $first,
            'last_name'  => $last,
            'consent'    => $consent,
            'total'      => (float) $cart->get_total( 'edit' ),
            'items'      => $items,
        );

        $body = wp_json_encode( $payload );
        $sig  = base64_encode( hash_hmac( 'sha256', $body, KWITKO_SF_SECRET, true ) );

        wp_remote_post( KWITKO_SF_CART_URL, array(
            'method'   => 'POST',
            'timeout'  => 5,
            'blocking' => false, // fire-and-forget so checkout/cart stays fast
            'headers'  => array(
                'Content-Type'      => 'application/json',
                'X-Kwitko-Signature'=> $sig,
            ),
            'body'     => $body,
        ) );
    }

    // Cart changes (logged-in shoppers, and guests once they have an email in session)
    add_action( 'woocommerce_add_to_cart',                  function () { kwitko_sync_cart_to_sf(); }, 20 );
    add_action( 'woocommerce_cart_item_removed',            function () { kwitko_sync_cart_to_sf(); }, 20 );
    add_action( 'woocommerce_after_cart_item_quantity_update', function () { kwitko_sync_cart_to_sf(); }, 20 );

    // Checkout: capture the email a guest types into the billing field (AJAX order-review refresh)
    add_action( 'woocommerce_checkout_update_order_review', function ( $post_data ) {
        parse_str( $post_data, $data );
        $email = isset( $data['billing_email'] ) ? sanitize_email( $data['billing_email'] ) : '';
        if ( ! empty( $email ) ) { kwitko_sync_cart_to_sf( $email ); }
    }, 20 );
}
