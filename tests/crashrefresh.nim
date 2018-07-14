import jester, asyncdispatch, htmlgen

routes:
  get "/secret/@filename":
    # verify access
    sendfile("public/root/" & @"filename")

  get "/pageok":
    resp h1("Hello world")

  get "/pagecrash":
    var html = "Crash due to sendfile()\n"
    html.add("<img src=\"/secret/secret.jpg\">")
    resp(html)

runForever()
