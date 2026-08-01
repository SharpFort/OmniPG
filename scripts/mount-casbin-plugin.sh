#!/bin/bash
# Mount authz-casbin plugin on all protected routes
# "Role in JWT" model: JWT claims["roles"] array → casbin policies (role → path → method)
set -euo pipefail

AUTH="X-API-KEY: edd1c9f034335f136f87ad84b625c8f1"
CT="Content-Type: application/json"
ADMIN="http://localhost:9180/apisix/admin"

# authz-casbin plugin config for Role-in-JWT
# username_source=jwt reads subject from JWT claims
# username_claim=sub uses the JWT "sub" claim (Casdoor user identifier)
# With g(r.sub, p.sub) matcher, user→role mapping comes from g policies
CASBIN_PLUGIN='"authz-casbin":{"username_source":"jwt","username_claim":"sub"}'

echo "=== Mounting authz-casbin on protected routes ==="

# Update each route to include authz-casbin after jwt-auth
for route_id in api_v1_sys api_v1_sales api_v1_inventory rpc_all catch_all; do
  # Get current route config
  current=$(curl -s "$ADMIN/routes/$route_id" -H "$AUTH")
  
  # Extract plugins and add authz-casbin
  new_body=$(echo "$current" | python3 -c "
import sys, json
d = json.load(sys.stdin)['value']
plugins = d.get('plugins', {})
plugins['authz-casbin'] = {'username_source': 'jwt', 'username_claim': 'sub'}
d['plugins'] = plugins
print(json.dumps(d))
" 2>/dev/null)
  
  if [ -n "$new_body" ]; then
    result=$(curl -s -X PUT "$ADMIN/routes/$route_id" -H "$AUTH" -H "$CT" -d "$new_body")
    status=$(echo "$result" | python3 -c "import sys,json; print('OK' if 'key' in json.load(sys.stdin) else 'FAIL')" 2>/dev/null)
    echo "  $route_id: $status"
  else
    echo "  $route_id: SKIP (no plugins)"
  fi
done

echo ""
echo "=== Verification ==="
curl -s "$ADMIN/routes" -H "$AUTH" | python3 -c "
import sys, json
routes = json.load(sys.stdin)['list']
for r in sorted(routes, key=lambda x: x.get('id','')):
    has_casbin = 'authz-casbin' in str(r.get('plugins', {}))
    has_jwt = 'jwt-auth' in str(r.get('plugins', {}))
    print(f\"  {r['id']:22s}  jwt:{'Y' if has_jwt else 'N'}  casbin:{'Y' if has_casbin else 'N'}\")
"
