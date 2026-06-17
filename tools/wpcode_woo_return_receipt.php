<?php
/**
 * Kwitko Woo Return Receipt -> Salesforce
 *
 * WPCode: PHP snippet, Active, Run Everywhere. Paste WITHOUT the opening <?php tag.
 *
 * Adds a WooCommerce admin order action: "Kwitko: mark return received".
 * When selected on a Woo order, it posts an HMAC-signed receipt event to Salesforce.
 * Salesforce then issues the Woo refund, closes the ReturnOrder, closes the Returns Case,
 * and adds a Woo customer note through its existing WooCommerce REST integration.
 */
if ( ! defined( 'ABSPATH' ) ) { exit; }

if ( ! function_exists( 'kwitko_sf_return_receipt_secret' ) ) {
  function kwitko_sf_return_receipt_secret() {
    return 'kwitko_whk_191b7c0315601372f98523adb3471095a8f1b05bf2bf8936';
  }
}

if ( ! function_exists( 'kwitko_sf_return_receipt_endpoint' ) ) {
  function kwitko_sf_return_receipt_endpoint() {
    return 'https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/woo/return-receipt/';
  }
}

add_filter( 'woocommerce_order_actions', function ( $actions ) {
  $actions['kwitko_mark_return_received'] = __( 'Kwitko: mark return received', 'kwitko' );
  return $actions;
} );

add_action( 'woocommerce_order_action_kwitko_mark_return_received', function ( $order ) {
  if ( ! ( $order instanceof WC_Order ) ) { return; }

  $user = wp_get_current_user();
  $payload = array(
    'order_id'      => (string) $order->get_id(),
    'order_number'  => (string) $order->get_order_number(),
    'received_note' => 'Woo admin marked returned merchandise received for order #' . $order->get_order_number(),
    'received_by'   => $user && $user->exists() ? $user->user_email : 'woocommerce-admin',
    'source'        => 'woocommerce_admin_order_action',
  );

  $body = wp_json_encode( $payload );
  $sig  = base64_encode( hash_hmac( 'sha256', $body, kwitko_sf_return_receipt_secret(), true ) );
  $resp = wp_remote_post( kwitko_sf_return_receipt_endpoint(), array(
    'headers' => array(
      'Content-Type'       => 'application/json',
      'X-Kwitko-Signature' => $sig,
    ),
    'body'     => $body,
    'timeout'  => 60,
    'blocking' => true,
  ) );

  if ( is_wp_error( $resp ) ) {
    $order->add_order_note( 'Kwitko return receipt sync failed: ' . $resp->get_error_message() );
    return;
  }

  $code = (int) wp_remote_retrieve_response_code( $resp );
  $text = wp_remote_retrieve_body( $resp );
  $data = json_decode( $text, true );
  if ( $code >= 200 && $code < 300 && is_array( $data ) && ! empty( $data['ok'] ) ) {
    $order->update_meta_data( '_kwitko_return_received_synced_at', gmdate( 'c' ) );
    if ( ! empty( $data['wooRefundId'] ) ) {
      $order->update_meta_data( '_kwitko_sf_woo_refund_id', sanitize_text_field( $data['wooRefundId'] ) );
    }
    if ( ! empty( $data['returnOrderNumber'] ) ) {
      $order->update_meta_data( '_kwitko_sf_return_order_number', sanitize_text_field( $data['returnOrderNumber'] ) );
    }
    $order->save();
    $order->add_order_note( 'Kwitko return receipt synced to Salesforce. ' . ( ! empty( $data['message'] ) ? $data['message'] : '' ) );
  } else {
    $order->add_order_note( 'Kwitko return receipt sync failed (' . $code . '): ' . $text );
  }
} );
