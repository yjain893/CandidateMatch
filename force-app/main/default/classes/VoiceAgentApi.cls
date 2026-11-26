/**
 * Lets the voice agent's API-only integration user read and change just what the agent needs, without access to the objects themselves.
 *   GET   /services/apexrest/voiceagent/query?q=...   accepts ONE of two fixed query shapes (an order by number, contacts by the last four digits of a phone) and answers with fixed queries
 *   PATCH /services/apexrest/voiceagent/order/{id}    changes only the five shipping address fields of one order
 * Anything else is refused. It runs without sharing because the integration user has no object permissions of its own.
 */
@RestResource(urlMapping='/voiceagent/*')
global without sharing class VoiceAgentApi {

    @TestVisible private static final Pattern ORDER_QUERY = Pattern.compile(
        '^SELECT ([A-Za-z0-9_., ]+) FROM Order WHERE OrderNumber = \'([0-9]{1,8})\' LIMIT 1$');
    @TestVisible private static final Pattern CONTACT_QUERY = Pattern.compile(
        '^SELECT ([A-Za-z0-9_., ]+) FROM Contact WHERE AccountId != null AND \\(Phone LIKE \'%([0-9]{4})\' OR MobilePhone LIKE \'%([0-9]{4})\'\\) LIMIT ([0-9]{1,2})$');

    private static final Set<String> ORDER_READ = new Set<String>{
        'id', 'ordernumber', 'status', 'effectivedate', 'enddate', 'totalamount',
        'shippingstreet', 'shippingcity', 'shippingstate', 'shippingpostalcode', 'shippingcountry'};
    private static final Set<String> CONTACT_READ = new Set<String>{
        'id', 'firstname', 'email', 'accountid', 'phone', 'mobilephone'};
    private static final Map<String, Integer> ORDER_WRITE = new Map<String, Integer>{
        'ShippingStreet' => 255, 'ShippingCity' => 40, 'ShippingState' => 80, 'ShippingPostalCode' => 20, 'ShippingCountry' => 80};

    private static void reply(Integer status, Object body) {
        RestResponse res = RestContext.response;
        res.statusCode = status;
        res.addHeader('Content-Type', 'application/json');
        if (body != null) {
            res.responseBody = Blob.valueOf(JSON.serialize(body));
        }
    }

    private static void refuse(String message) {
        reply(400, new Map<String, Object>{'error' => message});
    }

    private static Boolean fieldsAllowed(String selectList, Set<String> allowed) {
        for (String field : selectList.split(',')) {
            if (!allowed.contains(field.trim().toLowerCase())) {
                return false;
            }
        }
        return true;
    }

    @HttpGet
    global static void query() {
        RestRequest req = RestContext.request;
        if (!req.requestURI.endsWith('/voiceagent/query')) {
            reply(404, new Map<String, Object>{'error' => 'unknown path'});
            return;
        }
        String q = req.params.get('q');
        if (String.isBlank(q)) {
            refuse('q is required');
            return;
        }
        // The request must match one of two fixed shapes. The values are then taken out of it and used in fixed queries:
        // a dynamic query on Contact or Order is refused for a user whose license does not include those objects, a fixed one is not.
        Matcher order = ORDER_QUERY.matcher(q);
        if (order.matches()) {
            if (!fieldsAllowed(order.group(1), ORDER_READ)) {
                refuse('field not allowed');
                return;
            }
            String orderNumber = order.group(2);
            List<Order> orders = [SELECT Id, OrderNumber, Status, EffectiveDate, EndDate, TotalAmount,
                                         ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry
                                  FROM Order WHERE OrderNumber = :orderNumber LIMIT 1];
            reply(200, new Map<String, Object>{'records' => orders});
            return;
        }
        Matcher contact = CONTACT_QUERY.matcher(q);
        if (contact.matches()) {
            if (!fieldsAllowed(contact.group(1), CONTACT_READ) || contact.group(2) != contact.group(3)) {
                refuse('field not allowed');
                return;
            }
            String endsWith = '%' + contact.group(2);
            Integer maxRows = Math.min(Integer.valueOf(contact.group(4)), 20);
            List<Contact> contacts = [SELECT Id, FirstName, Email, AccountId, Phone, MobilePhone
                                      FROM Contact WHERE AccountId != null AND (Phone LIKE :endsWith OR MobilePhone LIKE :endsWith) LIMIT :maxRows];
            reply(200, new Map<String, Object>{'records' => contacts});
            return;
        }
        refuse('query not allowed');
    }

    @HttpPatch
    global static void updateOrder() {
        RestRequest req = RestContext.request;
        List<String> parts = req.requestURI.split('/');
        if (parts.size() < 2 || parts[parts.size() - 2] != 'order') {
            reply(404, new Map<String, Object>{'error' => 'unknown path'});
            return;
        }
        Id orderId;
        try {
            orderId = Id.valueOf(parts[parts.size() - 1]);
        } catch (Exception e) {
            refuse('not a record id');
            return;
        }
        if (orderId.getSobjectType() != Order.SObjectType) {
            refuse('not an order id');
            return;
        }
        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
        } catch (Exception e) {
            refuse('body must be JSON');
            return;
        }
        if (body.isEmpty()) {
            refuse('nothing to change');
            return;
        }
        Order changes = new Order(Id = orderId);
        for (String key : body.keySet()) {
            if (!ORDER_WRITE.containsKey(key)) {
                refuse('field not allowed: ' + key);
                return;
            }
            Object raw = body.get(key);
            String text = raw == null ? null : String.valueOf(raw).trim();
            if (text != null && text.length() > ORDER_WRITE.get(key)) {
                refuse('too long: ' + key);
                return;
            }
            changes.put(key, text);
        }
        Database.SaveResult saved = Database.update(changes, false);
        if (!saved.isSuccess()) {
            refuse(saved.getErrors()[0].getMessage());
            return;
        }
        reply(204, null);
    }
}
