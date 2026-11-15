/**
 * Thin wrapper around Prompt Builder so the rest of the code never touches ConnectApi directly.
 * inputs: key = prompt template input name (without "Input:"), value = String (free text)
 *         or Map<String,String>{'id' => recordOrFileId} (record / File input).
 */
public with sharing class PromptRunner {
    public class PromptException extends Exception {}

    @TestVisible private static String mockResponse;
    @TestVisible private static Map<String, String> mockByTemplate;

    public static String run(String templateDevName, Map<String, Object> inputs) {
        if (mockByTemplate != null && mockByTemplate.containsKey(templateDevName)) { return mockByTemplate.get(templateDevName); }
        if (mockResponse != null) { return mockResponse; }

        ConnectApi.EinsteinPromptTemplateGenerationsInput req = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        req.isPreview = false;

        Map<String, ConnectApi.WrappedValue> params = new Map<String, ConnectApi.WrappedValue>();
        for (String key : inputs.keySet()) {
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = inputs.get(key);
            params.put('Input:' + key, wv);
        }
        req.inputParams = params;
        req.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        req.additionalConfig.numGenerations = 1;
        req.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation out =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateDevName, req);
        if (out == null || out.generations == null || out.generations.isEmpty()) {
            throw new PromptException('Prompt returned no generations');
        }
        return out.generations[0].text;
    }

    /** Strips markdown fences / chatter and returns just the JSON object. */
    public static String clean(String raw) {
        if (String.isBlank(raw)) { throw new PromptException('Empty prompt response'); }
        Integer s = raw.indexOf('{');
        Integer e = raw.lastIndexOf('}');
        if (s < 0 || e <= s) { throw new PromptException('No JSON object found in prompt response'); }
        return raw.substring(s, e + 1);
    }
}
