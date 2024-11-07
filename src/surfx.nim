import nim_webview_abi
import std/macros, std/macrocache, std/strformat, strutils, sequtils, std/sets, std/algorithm
import jsony
import std/tables
import std/unicode
import std/syncio

export jsony


template checkError*(r: webview_error_t) =
  if unlikely(r.cint != WEBVIEW_ERROR_OK.cint):
    case r.webview_error_t
    of WEBVIEW_ERROR_MISSING_DEPENDENCY:
      raise newException(WebViewRuntimeError, "Missing webview dependency")
    of WEBVIEW_ERROR_CANCELED:
      raise newException(WebViewRuntimeError, "Webview canceled")
    of WEBVIEW_ERROR_INVALID_STATE:
      raise newException(WebViewRuntimeError, "Invalid webview state")
    of WEBVIEW_ERROR_INVALID_ARGUMENT:
      raise newException(WebViewRuntimeError, "Invalid webview argument")
    of WEBVIEW_ERROR_UNSPECIFIED:
      raise newException(WebViewRuntimeError, "Unspecified webview error")
    of WEBVIEW_ERROR_DUPLICATE:
      raise newException(WebViewRuntimeError, "Something is duplicated")
    of WEBVIEW_ERROR_NOT_FOUND:
      raise newException(WebViewRuntimeError, "Something not found")
    else:
      raise newException(WebViewRuntimeError, "Unknown webview error")

type 
  WebViewControllerObj* = object
    handle: webview_t

  WebViewController* = ref WebViewControllerObj

  kstring* = string | cstring

  WebViewRuntimeError* = object of CatchableError

proc `=destroy`(controller: WebViewControllerObj) =
  if controller.handle != nil:
    if webview_destroy(controller.handle) != 0:
      debugEcho "Failed to destroy webview native handle"

proc `=wasMoved`(controller: var WebViewControllerObj) =
  controller.handle = nil 




const exportwProcs = CacheSeq"exportwProcs"

type
  BondFunction = ref object
    name: string
    uniqueName: string
    constNode: NimNode
    argTypes: NimNode
    returnType: NimNode

  BondPackage = ref object
    name: string
    funcs: Table[string, BondFunction]
    subPackages: Table[string, BondPackage]

func `$`*(b: BondFunction): string =
  result = b.name & "(" & b.argTypes.repr & ") -> " & b.returnType.repr

func `$`*(b: BondPackage, prefix: string = ""): string =
  result = prefix & b.name & ":\n"
  for (k, v) in b.funcs.pairs:
    result.add prefix & "  " & $v & "\n"
  for (k, v) in b.subPackages.pairs:
    result.add `$`(v, "  " & prefix)


func newBondFunction*(name: string, uniqueName: string, constNode: NimNode, argTypes: NimNode, returnType: NimNode) : BondFunction =
  result = BondFunction(name: name, uniqueName: uniqueName, constNode: constNode, argTypes: argTypes, returnType: returnType)

func newBondPackage*(name: string) : BondPackage =
  result = BondPackage(name: name, funcs: initTable[string, BondFunction](), subPackages: initTable[string, BondPackage]())

func loadBondFunctionsFromCache() : BondPackage =
  result = newBondPackage("surfx")

  var idx = 0
  for n in exportwProcs:
    let full_name = n[0].strVal
    var parts = full_name.split(".")
    parts.reverse()
    var pack = result
    while parts.len > 1:
      let p = parts.pop()
      if not pack.subPackages.hasKey(p):
        pack.subPackages[p] = newBondPackage(p)
      pack = pack.subPackages[p]
    let name = parts.pop()
    
    if pack.funcs.hasKey(name):
      raise newException(ValueError, "Duplicate function: " & full_name)
    pack.funcs[name] = newBondFunction(name, "__surfxf__" & $idx, n[1], n[2], n[3])
    idx += 1

include "surfx/surfx_js.nimf"
include "surfx/surfx_jsinit.nimf"

func newWebViewControllerImpl*(title: kstring, url: kstring; width: int = 800, height: int = 600, initJS: kstring = ""): WebViewController =
  var controller = WebViewController()
  when not defined(release):
    let debug : cint = 1
  else:
    let debug : cint = 0
  controller.handle = webview_create(debug, nil)
  if controller.handle == nil:
    raise newException(WebViewRuntimeError, "Failed to create webview")
  checkError webview_set_title(controller.handle, title.cstring)
  checkError webview_set_size(controller.handle, width.cint, height.cint, WEBVIEW_HINT_NONE)
  checkError webview_navigate(controller.handle, url)
  if len(initJS) > 0:
    checkError webview_init(controller.handle, initJS)
  result = controller

macro newWebViewController*(title: kstring, url: kstring; width: int = 800, height: int = 600, initJS: kstring = "") : WebViewController =
  result = newStmtList()
  
  let root = loadBondFunctionsFromCache()
  let cVar = genSym(nskVar, "c")

  result.add quote do:
    var `cVar` = newWebViewControllerImpl(`title`, `url`, `width`, `height`, `initJS`)

  ## generate JS init script and bind functions
  var jsInitScript = generateJsInit(root)

  ## bind functions
  proc bindFunctions(pack: BondPackage, stmts: var NimNode) =
    for (k, v) in pack.funcs.pairs:
      let uniqueName = v.uniqueName
      let constNode = v.constNode
      stmts.add quote do:      
        checkError webview_bind(`cVar`.handle, `uniqueName`, `constNode`, cast[pointer](`cVar`))
    for (k, v) in pack.subPackages.pairs:
      bindFunctions(v, stmts)

  bindFunctions(root, result)

  ## generate Nim file to compile in js
  let nimFile = "src/ui/surfx_js.nim"
  let nimFileContent = generateSurfxPrelude(root)
  writeFile(nimFile, nimFileContent)

  echo nimFileContent


  result.add quote do:      
    checkError webview_init(`cVar`.handle, `jsInitScript`.cstring)
    `cVar`


proc run*(controller: WebViewController) =
  checkError webview_run(controller.handle)

proc terminate*(controller: WebViewController) =
  checkError webview_terminate(controller.handle)



    
proc exportw_impl(name: string, p: NimNode) : NimNode =
  expectKind(p, RoutineNodes)

  let procName = p[0]
  let newProcName = genSym(nskConst, $procName)
  let params = p[3][2 .. ^1]
  let returnType = p[3][0]
  
  addPragma(p, ident"gcsafe")
  addPragma(p, newTree(nnkExprColonExpr, ident"raises", newNimNode(nnkBracket)))

  result = newStmtList()
  result.add p

  # Create a tuple type for the arguments
  let tupleTy = newNimNode(nnkTupleTy)
  for n in params:
    tupleTy.add n

  # Build a call expression with JSON parsing and type conversions for arguments
  var callArgs = newSeq[NimNode]()
  let argsParsed = newIdentNode("argsParsed")
  let controllerCasted = newIdentNode("controller")

  callArgs.add controllerCasted
  for i, param in params:
    let paramName = param[0]
    let paramType = param[1]
    callArgs.add quote do:
      `argsParsed`[`i`]

  var call = newNimNode(nnkCall)
  call.add(procName)
  call.add(callArgs)

  if returnType.repr == "":
    result.add quote do:
      const `newProcName` = proc (id: cstring; req: cstring; arg: pointer) {.cdecl, gcsafe, raises:[].} =
        type argTypes = `tupleTy`
        let argsString = $req
        let `controllerCasted` = cast[WebViewController](arg)
        try:
          let `argsParsed` = argsString.fromJson(argTypes)

          `call`
          checkError webview_return(`controllerCasted`.handle, id, 0, "".cstring)
        except CatchableError as e:
          echo "Error parsing arguments:", e.msg
          discard webview_return(`controllerCasted`.handle, id, -1, "".cstring)
  else:
    result.add quote do:
      const `newProcName` = proc (id: cstring; req: cstring; arg: pointer) {.cdecl, gcsafe, raises:[].} =
        type argTypes = `tupleTy`
        let argsString = $req
        let `controllerCasted` = cast[WebViewController](arg)
        try:
          let `argsParsed` = argsString.fromJson(argTypes)

          let callR = `call`
          discard webview_return(`controllerCasted`.handle, id, 0, callR.toJson().cstring)
        except CatchableError as e:
          echo "Error parsing arguments:", e.msg
          discard webview_return(`controllerCasted`.handle, id, -1, "".cstring)
  
  # resolve the full name of the proc (including the packages)
  let resolvedName = name % [procName.strVal]
  
  #echo result.repr
  exportwProcs.add newTree(nnkTupleConstr, newLit(resolvedName), newProcName, tupleTy, returnType)
  
  

macro exportw*(p: untyped) : untyped =
  expectKind(p, RoutineNodes)
  
  result = exportw_impl("$1", p)

macro exportw*(name: untyped, p: untyped) : untyped =
  expectKind(name, nnkStrLit)
  expectKind(p, RoutineNodes)

  result = exportw_impl(name.strVal, p)

func generateNimJS*() : string =
  ## Get the path to the JS file that will be used to bind Nim procs to JS functions
