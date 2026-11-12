# Validate only after checking the signature of the exact input bytes.
# No regex functions: standard OpenWrt jq does not require oniguruma.
def token($max):
  type == "string" and length > 0 and length <= $max and
  ((explode - ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-~" | explode)) | length == 0);
def integer($max): type == "number" and . > 0 and . <= $max and floor == .;
def hash: type == "string" and length == 64 and
  ((explode - ("0123456789abcdef" | explode)) | length == 0);
def artifact($format):
  type == "object" and keys == ["file", "installed_size", "sha256", "size"] and
  (.file | token(128) and (startswith(".") | not) and (contains("..") | not) and endswith("." + $format)) and
  (.sha256 | hash) and (.size | integer(67108864)) and (.installed_size | integer(134217728));
def package($format):
  type == "object" and keys == ["forward", "from", "name", "rollback", "to"] and
  (.name == "xkop" or .name == "luci-app-xkop" or .name == "xray-xkop") and
  (.from | token(64)) and (.to | token(64)) and .from != .to and
  (.forward | artifact($format)) and (.rollback | artifact($format));
type == "object" and
keys == ["arch", "expires", "format", "issued", "openwrt_series", "packages", "schema"] and
.schema == 1 and (.format == "apk" or .format == "ipk") and
(.arch | token(64)) and (.openwrt_series | token(16)) and
(.issued | integer(4102444800)) and (.expires | integer(4102444800)) and
.issued <= ($now + 300) and .expires > $now and .expires > .issued and
.expires <= (.issued + 2592000) and
(.format as $format | .packages | type == "array" and length >= 1 and length <= 3 and all(.[]; package($format))) and
([.packages[].name] | length == (unique | length)) and
([.packages[].name] | index("xkop") != null) and
([.packages[] | .forward.file, .rollback.file] | length == (unique | length)) and
([.packages[] | select(.name == "xkop" or .name == "luci-app-xkop") | .to] | unique | length == 1)
