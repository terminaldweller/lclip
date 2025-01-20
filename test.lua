#!/usr/bin/env lua5.3

local luaunit = require("luaunit")
local ollama = require("ollama")

local args = {}
args["ollama_endpoint"] = "http://172.17.0.1:11434/api/chat"
args["ollama_model"] = "llama3.1"

luaunit.assertEquals(ollama.ask_ollama(
                         "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEs3GbmHMO0n1rL2vsn7+AH9xJwZ9BOUU6rR6x7hW8uX devi@terminaldweller.com",
                         args, 5), true)
luaunit.assertEquals(ollama.ask_ollama('password="12345661234"', args, 5), true)
luaunit.assertEquals(ollama.ask_ollama(
                         "W65X2UljhbM0H9kTVogZ8TnCnIqPbCvvqVUsjZ9gWxjWgFiR1Uzolouc1ghKXUyqinhVcZ1lHnXWv2jHoVRU0dC0DZdyDgYfUiHdBwAeqryc0fT6d7nxgs0UErgwOkNt8S9tKUwadRscS8VV7q2j6F5FvSfyTGflluminatevrFOcGwD1RXkJP0J2aVQWxCCszvTSNhRPTM3TeUw8dXoapXTb2IcSUwKCvAdEhemFOsgU27wF7vHYDrm6GMVofZEwAitpVQxDDPvl7qefIuXdFuDJthnxH8uUJpEbSTWXyFLaE0n5QS063grrx0ar1TCxOpJiiGTSadDeTx8OQAyemqQYj7LoYCkdKCHX7G8VSEuJlFJ6R2CM",
                         args, 5), true)
luaunit.assertEquals(ollama.ask_ollama('hello my name is', args, 5), false)
