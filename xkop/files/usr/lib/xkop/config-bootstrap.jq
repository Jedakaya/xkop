# Only a loopback tunnel for obtaining the assets required by the full config.
[.outbounds[] | select(.protocol != "freedom" and .protocol != "blackhole" and .protocol != "dns") | .tag] as $nodes
| (.routing.balancers[0].fallbackTag // "") as $manual
| (if ($nodes | index($pin)) != null then $pin
   elif ($nodes | index($auto_pin)) != null then $auto_pin
   elif ($nodes | index($manual)) != null then $manual
   else ($nodes[0] // "block") end) as $target
| del(.dns, .fakedns, .burstObservatory)
| .api.services |= map(select(. != "ObservatoryService"))
| .inbounds |= map(select(.tag == "probe-in")
    | .sniffing.destOverride |= map(select(. != "fakedns")))
| .outbounds |= map(select(.protocol != "dns"))
| .routing.balancers = []
| .routing.rules = [{type: "field", inboundTag: ["probe-in"], outboundTag: $target}]
