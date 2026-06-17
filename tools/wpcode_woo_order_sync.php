<?php
/**
 * Kwitko Woo→SF Order Sync — DEPLOYED LIVE as WPCode snippet_id=508 (PHP, Active, Run Everywhere).
 * On ANY WooCommerce order change (status change, admin edit, new order) it POSTs the order
 * (HMAC-signed with the shared Woo_Settings__c.Webhook_Secret__c, header X-WC-Webhook-Signature)
 * to the Salesforce Woo webhook endpoint, which runs WooOrderService.ingestOrder → reconcile-or-create.
 *
 * Endpoint (MUST be the salesforce-sites.com domain — my.site.com returns 301 which wp_remote_post
 * won't follow on POST):
 *   https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/woo/order/
 *
 * In WPCode the snippet body is the PHP BELOW WITHOUT the opening <?php tag.
 */
if ( ! function_exists( 'kwitko_push_order_to_sf' ) ) {
  function kwitko_push_order_to_sf( $order_id, $order = null ) {
    if ( ! $order_id || ! function_exists( 'wc_get_order' ) ) { return; }
    static $sent = array();
    if ( isset( $sent[ $order_id ] ) ) { return; }
    $sent[ $order_id ] = true;
    if ( ! ( $order instanceof WC_Order ) ) { $order = wc_get_order( $order_id ); }
    if ( ! $order ) { return; }
    $status = $order->get_status();
    if ( in_array( $status, array( 'checkout-draft', 'auto-draft', 'trash' ), true ) ) { return; }
    $items = array();
    foreach ( $order->get_items() as $it ) {
      $p = $it->get_product();
      $items[] = array( 'product_id' => $it->get_product_id(), 'name' => $it->get_name(), 'quantity' => $it->get_quantity(), 'total' => $it->get_total(), 'sku' => $p ? $p->get_sku() : '' );
    }
    $meta = array();
    foreach ( array( '_wc_shipment_tracking_items', '_tracking_number', '_tracking_provider', '_aftership_tracking_number', '_aftership_tracking_provider' ) as $k ) {
      $v = $order->get_meta( $k );
      if ( ! empty( $v ) ) { $meta[] = array( 'key' => $k, 'value' => $v ); }
    }
    $paid = $order->get_date_paid();
    $payload = array(
      'id' => $order->get_id(), 'status' => $status, 'total' => $order->get_total(), 'currency' => $order->get_currency(),
      'date_paid' => $paid ? $paid->date( 'c' ) : null, 'customer_id' => $order->get_customer_id(),
      'billing' => array( 'email' => $order->get_billing_email(), 'first_name' => $order->get_billing_first_name(), 'last_name' => $order->get_billing_last_name(), 'phone' => $order->get_billing_phone() ),
      'shipping' => array( 'address_1' => $order->get_shipping_address_1(), 'city' => $order->get_shipping_city(), 'state' => $order->get_shipping_state(), 'postcode' => $order->get_shipping_postcode(), 'country' => $order->get_shipping_country() ),
      'line_items' => $items, 'meta_data' => $meta,
    );
    $body = wp_json_encode( $payload );
    $secret = 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936';
    $sig = base64_encode( hash_hmac( 'sha256', $body, $secret, true ) );
    wp_remote_post( 'https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/woo/order/', array( 'headers' => array( 'Content-Type' => 'application/json', 'X-WC-Webhook-Signature' => $sig ), 'body' => $body, 'timeout' => 20, 'blocking' => false ) );
  }
  add_action( 'woocommerce_update_order', 'kwitko_push_order_to_sf', 20, 2 );
  add_action( 'woocommerce_new_order', 'kwitko_push_order_to_sf', 20, 2 );
  add_action( 'woocommerce_order_status_changed', function ( $oid, $from, $to, $order ) { kwitko_push_order_to_sf( $oid, $order ); }, 20, 4 );
}
