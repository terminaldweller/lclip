local http_request = require("http.request")
local libgen = require("posix.libgen")

local base_path = libgen.dirname(arg[0])
package.path = package.path .. ";" .. base_path .. "/?.lua"
local json = require("json")
local cq = require("cqueues")

local ollama = {}

local loop = cq.new()

function ollama.ollama_req(clipboard_content, args)
    local url = args["ollama_endpoint"]
    local req = http_request.new_from_uri(url)

    local body = {
        model = args["ollama_model"],
        stream = false,
        format = "json",
        messages = {
            {content = clipboard_content, role = "user"}, {
                content = [[
            Learn the following rules. the rules are provided in no particular order:
            ---
            a public key of an assymetric key-pair is a secret.
            a private key of an assymetric key-pair is a secret.
            an api key is a secret.
            a password is a secret.
            a token used for authentication or authorization is a secret.
            a key-value pair is a secret if the key contains the word 'password'or 'secret' or 'token' or 'key'.
            a string containing the word 'password' or 'secret' or 'token' or 'key' is a secret.
            a string that contains a word longer than 20 characters is a secret.
            a word that is not part of any of the languages you know which is longer than 20 characters is a secret.
            a long string of random characters is a secret.
            one matching positive matching criteria is enough to consider a string a secret.
            ---
            ]],
                role = "assistant"
            }, {
                content = [[
                Only answer in json.
                The answer must a field named 'isSecret'.
                The answer must have a field named 'reasoning'.
                The value of 'isSecret' must be a boolean.
                The value of reasoning must be a string.
                You must give a reason.
                The reason must be the criteria that was used to determine if the string is a secret.
                The answer must be valid json.
                ]],
                role = "assistant"
            }, {
                content = [[
                Now I will give you your task.
                Look at the user-provided string content.
                Is it a secret? answer in json.
                ]],
                role = "assistant"
            }
        },
        options = {
            temperature = 0.5,
            max_tokens = 10000,
            top_p = 1.0,
            frequency_penalty = 0.0,
            presence_penalty = 0.0
        }
    }

    local body_json = json.encode(body)
    req:set_body(body_json)

    req.headers:upsert(":method", "POST")

    local headers, stream = req:go(10000)

    if headers:get(":status") ~= "200" then return nil end

    local result_body = stream:get_body_as_string()

    return result_body
end

function ollama.ask_ollama(clipboard_content, args, count)
    local true_count = 0
    local false_count = 0
    loop:wrap(function()
        for _ = 1, count do
            loop:wrap(function()
                local result = ollama.ollama_req(clipboard_content, args)
                local result_decoded = json.decode(result)
                local final_result = json.decode(
                                         result_decoded["message"]["content"])
                for k, v in pairs(final_result) do print(k, v) end
                if final_result["isSecret"] == true then
                    true_count = true_count + 1
                else
                    false_count = false_count + 1
                end
                print("True count: " .. true_count)
                print("False count: " .. false_count)
            end)
        end
    end)
    loop:loop()

    print("True count: " .. true_count)
    print("False count: " .. false_count)
    if false_count > true_count then
        return false
    else
        return true
    end
end

return ollama
