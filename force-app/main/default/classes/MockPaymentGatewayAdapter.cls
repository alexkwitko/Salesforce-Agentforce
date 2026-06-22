/**
 * MockPaymentGatewayAdapter — demo payment gateway that always approves, so D2C checkout completes
 * in a dev org. Handles Tokenize (the /payments/token call), Authorize, Capture, and Sale.
 * Swap for a real adapter (Stripe/Payeezy) in production.
 */
global with sharing class MockPaymentGatewayAdapter implements CommercePayments.PaymentGatewayAdapter {
    global CommercePayments.GatewayResponse processRequest(CommercePayments.paymentGatewayContext ctx) {
        CommercePayments.RequestType t = ctx.getPaymentRequestType();
        if (t == CommercePayments.RequestType.Tokenize) {
            CommercePayments.PaymentMethodTokenizationResponse res = new CommercePayments.PaymentMethodTokenizationResponse();
            res.setGatewayToken('DEMO-TOKEN-' + String.valueOf(Datetime.now().getTime()));
            res.setGatewayResultCode('00');
            res.setGatewayResultCodeDescription('Tokenized');
            res.setGatewayDate(Datetime.now());
            res.setSalesforceResultCodeInfo(new CommercePayments.SalesforceResultCodeInfo(CommercePayments.SalesforceResultCode.Success));
            return res;
        } else if (t == CommercePayments.RequestType.Authorize) {
            CommercePayments.AuthorizationRequest req = (CommercePayments.AuthorizationRequest) ctx.getPaymentRequest();
            CommercePayments.AuthorizationResponse res = new CommercePayments.AuthorizationResponse();
            res.setAmount(req.amount);
            res.setGatewayResultCode('00');
            res.setGatewayResultCodeDescription('Approved');
            res.setGatewayAuthCode('DEMOAUTH');
            res.setGatewayReferenceNumber('AUTH-' + String.valueOf(Datetime.now().getTime()));
            res.setSalesforceResultCodeInfo(new CommercePayments.SalesforceResultCodeInfo(CommercePayments.SalesforceResultCode.Success));
            return res;
        } else if (t == CommercePayments.RequestType.Capture) {
            CommercePayments.CaptureRequest req = (CommercePayments.CaptureRequest) ctx.getPaymentRequest();
            CommercePayments.CaptureResponse res = new CommercePayments.CaptureResponse();
            res.setAmount(req.amount);
            res.setGatewayResultCode('00');
            res.setGatewayResultCodeDescription('Captured');
            res.setGatewayReferenceNumber('CAP-' + String.valueOf(Datetime.now().getTime()));
            res.setSalesforceResultCodeInfo(new CommercePayments.SalesforceResultCodeInfo(CommercePayments.SalesforceResultCode.Success));
            return res;
        } else if (t == CommercePayments.RequestType.Sale) {
            CommercePayments.SaleRequest req = (CommercePayments.SaleRequest) ctx.getPaymentRequest();
            CommercePayments.SaleResponse res = new CommercePayments.SaleResponse();
            res.setAmount(req.amount);
            res.setGatewayResultCode('00');
            res.setGatewayResultCodeDescription('Sale Approved');
            res.setGatewayReferenceNumber('SALE-' + String.valueOf(Datetime.now().getTime()));
            res.setSalesforceResultCodeInfo(new CommercePayments.SalesforceResultCodeInfo(CommercePayments.SalesforceResultCode.Success));
            return res;
        }
        CommercePayments.GatewayErrorResponse err = new CommercePayments.GatewayErrorResponse('500', 'Unsupported request type');
        return err;
    }
}
