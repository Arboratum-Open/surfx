# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest

import surfx
test "create/destroy webview":
  var controller = newWebViewController("Basic Example", "https://nim-lang.org")

  terminate(controller)


test "create webview and bind void function":

  let baseJS = """
    setTimeout(() => {
      surfx.close_app(5);
    }, 2000);
  """
  proc close_app(c: WebViewController, code: int) {.exportw.} =
    echo "close_app called"
    try:
      check code == 5
      terminate(c)
    except WebViewRuntimeError as e:
      echo "Failed to terminate webview"
    except ValueError as e:
      echo "Invalid code:", e.msg
    except Exception as e:
      echo "Unknown error:", e.msg

  var controller = newWebViewController("Basic Example", "https://nim-lang.org", initJS = baseJS)



  run(controller)
  
  
test "create webview and bind non-void function":
  
    let baseJS = """
      setTimeout(() => {
        var x = surfx.app.generate_html(5, "mama");
        console.log(x);
        x.then((x) => {
          console.log(x);
          document.body.innerHTML = x
          setTimeout(() => {
            surfx.close_app(5).then((x) => {
              console.log(x);
            });
          }, 2000);

        });
        

      }, 2000);
    """

    echo "thread id:", getThreadId()

    proc generate_html(c: WebViewController, code: int, text: string): string {.exportw:"app.$1".} =
      echo "generate_html called"
      echo "call thread id:", getThreadId()
      return "<h1>" & $code & " " & text & "</h1>"

    var controller = newWebViewController("Basic Example", "https://nim-lang.org", initJS = baseJS)

    run(controller)
