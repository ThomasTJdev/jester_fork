import uri, cgi, tables, logging, strutils, re, options
from sequtils import map

import private/utils

when useHttpBeast:
  import httpbeastfork except Settings
  import options, httpcore

  type
    NativeRequest* = httpbeastfork.Request
else:
  import asynchttpserver

  type
    NativeRequest* = asynchttpserver.Request

type
  Request* = object
    req: NativeRequest
    patternParams: Option[Table[string, string]]
    reMatches: array[MaxSubpatterns, string]
    settings*: Settings

proc body*(req: Request): string =
  ## Body of the request, only for POST.
  ##
  ## You're probably looking for ``formData``
  ## instead.
  when useHttpBeast:
    req.req.body.get("")
  else:
    req.req.body

proc headers*(req: Request): HttpHeaders =
  ## Headers received with the request.
  ## Retrieving these is case insensitive.
  when useHttpBeast:
    if req.req.headers.isNone:
      newHttpHeaders()
    else:
      req.req.headers.get()
  else:
    req.req.headers

proc path*(req: Request): string =
  ## Path of request without the query string.
  when useHttpBeast:
    let p = req.req.path.get("")
    let queryStart = p.find('?')
    if unlikely(queryStart != -1):
      return p[0 .. queryStart-1]
    else:
      return p
  else:
    let u = req.req.url
    return u.path

proc query*(req: Request): string =
  ## Query string of request
  when useHttpBeast:
    let p = req.req.path.get("")
    let queryStart = p.find('?')
    if likely(queryStart != -1):
      return p[queryStart + 1 .. ^1]
    else:
      return ""
  else:
    let u = req.req.url
    return u.query

proc reqMethod*(req: Request): HttpMethod =
  ## Request method, eg. HttpGet, HttpPost
  when useHttpBeast:
    req.req.httpMethod.get()
  else:
    req.req.reqMethod

proc reqMeth*(req: Request): HttpMethod {.deprecated.} =
  req.reqMethod

proc ip*(req: Request): string =
  ## IP address of the requesting client.
  when useHttpBeast:
    result = req.req.ip
  else:
    result = req.req.hostname

  let headers = req.headers
  if headers.hasKey("REMOTE_ADDR"):
    result = headers["REMOTE_ADDR"]
  if headers.hasKey("x-forwarded-for"):
    result = headers["x-forwarded-for"]

proc params*(req: Request): Table[string, string] =
  ## Parameters from the pattern and the query string.
  ##
  ## Note that this doesn't allow for duplicated keys (it simply returns the last occuring value)
  ## Use `paramValuesAsSeq` if you need multiple values for a key
  if req.patternParams.isSome():
    result = req.patternParams.get()
  else:
    result = initTable[string, string]()

  var queriesToDecode: seq[string] = @[]
  queriesToDecode.add query(req)

  let contentType = req.headers.getOrDefault("Content-Type")
  if contentType.startswith("application/x-www-form-urlencoded"):
    queriesToDecode.add req.body

  for query in queriesToDecode:
    try:
      for key, val in cgi.decodeData(query):
        result[key] = decodeUrl(val)
    except CgiError:
      logging.warn("Incorrect query. Got: $1" % [query])

proc paramValuesAsSeq*(req: Request): Table[string, seq[string]] =
  ## Parameters from the pattern and the query string.
  ##
  ## This allows for duplicated keys in the query (in contrast to `params`)
  if req.patternParams.isSome():
    let patternParams: Table[string, string] = req.patternParams.get()
    var patternParamsSeq: seq[(string, string)] = @[]
    for key, val in pairs(patternParams):
      patternParamsSeq.add (key, val)

    # We are not url-decoding the key/value for the patternParams (matches implementation in `params`
    result = sequtils.map(patternParamsSeq,
              proc(entry: (string, string)): (string, seq[string]) =
                (entry[0], @[entry[1]])
    ).toTable()
  else:
    result = initTable[string, seq[string]]()

  var queriesToDecode: seq[string] = @[]
  queriesToDecode.add query(req)

  let contentType = req.headers.getOrDefault("Content-Type")
  if contentType.startswith("application/x-www-form-urlencoded"):
    queriesToDecode.add req.body

  for query in queriesToDecode:
    try:
      for key, value in cgi.decodeData(query):
        if result.hasKey(key):
          result[key].add value
        else:
          result[key] = @[value]
    except CgiError:
      logging.warn("Incorrect query. Got: $1" % [query])

proc formData*(req: Request): MultiData =
  let contentType = req.headers.getOrDefault("Content-Type")
  if contentType.startsWith("multipart/form-data"):
    result = parseMPFD(contentType, req.body)

proc matches*(req: Request): array[MaxSubpatterns, string] =
  req.reMatches

proc secure*(req: Request): bool =
  if req.headers.hasKey("x-forwarded-proto"):
    let proto = req.headers["x-forwarded-proto"]
    case proto.toLowerAscii()
    of "https":
      result = true
    of "http":
      result = false
    else:
      logging.warn("Unknown x-forwarded-proto ", proto)

proc port*(req: Request): int =
  if (let p = req.headers.getOrDefault("SERVER_PORT"); p != ""):
    result = p.parseInt
  else:
    result = if req.secure: 443 else: 80

proc host*(req: Request): string =
  req.headers.getOrDefault("HOST")

proc appName*(req: Request): string =
  ## This is set by the user in ``run``, it is
  ## overriden by the "SCRIPT_NAME" scgi
  ## parameter.
  req.settings.appName

proc stripAppName(path, appName: string): string =
  result = path
  if appname.len > 0:
    var slashAppName = appName
    if slashAppName[0] != '/' and path[0] == '/':
      slashAppName = '/' & slashAppName

    if path.startsWith(slashAppName):
      if slashAppName.len() == path.len:
        return "/"
      else:
        return path[slashAppName.len .. path.len-1]
    else:
      raise newException(ValueError,
          "Expected script name at beginning of path. Got path: " &
           path & " script name: " & slashAppName)

proc pathInfo*(req: Request): string =
  ## This is ``.path`` without ``.appName``.
  req.path.stripAppName(req.appName)

# TODO: Can cookie keys be duplicated?
proc cookies*(req: Request): Table[string, string] =
  ## Cookies from the browser.
  if (let cookie = req.headers.getOrDefault("Cookie"); cookie != ""):
    result = parseCookies(cookie)
  else:
    result = initTable[string, string]()

#[ Protected procs ]#

proc initRequest*(req: NativeRequest, settings: Settings): Request {.inline.} =
  Request(
    req: req,
    settings: settings
  )

proc getNativeReq*(req: Request): NativeRequest =
  req.req

#[ Only to be used by our route macro. ]#
proc setPatternParams*(req: var Request, p: Table[string, string]) =
  req.patternParams = some(p)

proc setReMatches*(req: var Request, r: array[MaxSubpatterns, string]) =
  req.reMatches = r
