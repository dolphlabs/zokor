wrk.method = "POST"
wrk.body = '{"message":"hello from the load generator, a realistically small JSON body"}'
wrk.headers["Content-Type"] = "application/json"
