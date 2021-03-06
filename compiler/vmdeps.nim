#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import ast, types, msgs, osproc, streams, options, idents, securehash

proc readOutput(p: Process): string =
  result = ""
  var output = p.outputStream
  while not output.atEnd:
    result.add(output.readLine)
    result.add("\n")
  if result.len > 0:
    result.setLen(result.len - "\n".len)
  discard p.waitForExit

proc opGorge*(cmd, input, cache: string): string =
  if cache.len > 0:# and optForceFullMake notin gGlobalOptions:
    let h = secureHash(cmd & "\t" & input & "\t" & cache)
    let filename = options.toGeneratedFile("gorge_" & $h, "txt")
    var f: File
    if open(f, filename):
      result = f.readAll
      f.close
      return
    var readSuccessful = false
    try:
      var p = startProcess(cmd, options={poEvalCommand, poStderrToStdout})
      if input.len != 0:
        p.inputStream.write(input)
        p.inputStream.close()
      result = p.readOutput
      readSuccessful = true
      writeFile(filename, result)
    except IOError, OSError:
      if not readSuccessful: result = ""
  else:
    try:
      var p = startProcess(cmd, options={poEvalCommand, poStderrToStdout})
      if input.len != 0:
        p.inputStream.write(input)
        p.inputStream.close()
      result = p.readOutput
    except IOError, OSError:
      result = ""

proc opSlurp*(file: string, info: TLineInfo, module: PSym): string =
  try:
    let filename = file.findFile
    result = readFile(filename)
    # we produce a fake include statement for every slurped filename, so that
    # the module dependencies are accurate:
    appendToModule(module, newNode(nkIncludeStmt, info, @[
      newStrNode(nkStrLit, filename)]))
  except IOError:
    localError(info, errCannotOpenFile, file)
    result = ""

proc atomicTypeX(name: string; t: PType; info: TLineInfo): PNode =
  let sym = newSym(skType, getIdent(name), t.owner, info)
  sym.typ = t
  result = newSymNode(sym)
  result.typ = t

proc mapTypeToAstX(t: PType; info: TLineInfo;
                   inst=false; allowRecursionX=false): PNode

proc mapTypeToBracketX(name: string; t: PType; info: TLineInfo;
                       inst=false): PNode =
  result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
  result.add atomicTypeX(name, t, info)
  for i in 0 .. < t.len:
    if t.sons[i] == nil:
      let void = atomicTypeX("void", t, info)
      void.typ = newType(tyEmpty, t.owner)
      result.add void
    else:
      result.add mapTypeToAstX(t.sons[i], info, inst)

proc mapTypeToAstX(t: PType; info: TLineInfo;
                   inst=false; allowRecursionX=false): PNode =
  var allowRecursion = allowRecursionX
  template atomicType(name): expr = atomicTypeX(name, t, info)
  template mapTypeToAst(t,info): expr = mapTypeToAstX(t, info, inst)
  template mapTypeToAstR(t,info): expr = mapTypeToAstX(t, info, inst, true)
  template mapTypeToAst(t,i,info): expr =
    if i<t.len and t.sons[i]!=nil: mapTypeToAstX(t.sons[i], info, inst)
    else: ast.emptyNode
  template mapTypeToBracket(name,t,info): expr =
    mapTypeToBracketX(name, t, info, inst)
  template newNodeX(kind):expr =
    newNodeIT(kind, if t.n.isNil: info else: t.n.info, t)
  template newIdent(s):expr =
    var r = newNodeX(nkIdent)
    r.add !s
    r
  template newIdentDefs(n,t):expr =
    var id = newNodeX(nkIdentDefs)
    id.add n  # name
    id.add mapTypeToAst(t, info)  # type
    id.add ast.emptyNode  # no assigned value
    id
  template newIdentDefs(s):expr = newIdentDefs(s, s.typ)

  if inst:
    if t.sym != nil:  # if this node has a symbol
      if allowRecursion:  # getTypeImpl behavior: turn off recursion
        allowRecursion = false
      else:  # getTypeInst behavior: return symbol
        return atomicType(t.sym.name.s)

  case t.kind
  of tyNone: result = atomicType("none")
  of tyBool: result = atomicType("bool")
  of tyChar: result = atomicType("char")
  of tyNil: result = atomicType("nil")
  of tyExpr: result = atomicType("expr")
  of tyStmt: result = atomicType("stmt")
  of tyEmpty: result = atomicType"void"
  of tyArrayConstr, tyArray:
    result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
    result.add atomicType("array")
    if inst and t.sons[0].kind == tyRange:
      var rng = newNodeX(nkInfix)
      rng.add newIdentNode(getIdent(".."), info)
      rng.add t.sons[0].n.sons[0].copyTree
      rng.add t.sons[0].n.sons[1].copyTree
      result.add rng
    else:
      result.add mapTypeToAst(t.sons[0], info)
    result.add mapTypeToAst(t.sons[1], info)
  of tyTypeDesc:
    if t.base != nil:
      result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
      result.add atomicType("typeDesc")
      result.add mapTypeToAst(t.base, info)
    else:
      result = atomicType"typeDesc"
  of tyGenericInvocation:
    result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
    for i in 0 .. < t.len:
      result.add mapTypeToAst(t.sons[i], info)
  of tyGenericInst:
    if inst:
      if allowRecursion:
        result = mapTypeToAstR(t.lastSon, info)
      else:
        result = newNodeX(nkBracketExpr)
        result.add mapTypeToAst(t.lastSon, info)
        for i in 1 .. < t.len-1:
          result.add mapTypeToAst(t.sons[i], info)
    else:
      result = mapTypeToAst(t.lastSon, info)
  of tyGenericBody, tyOrdinal, tyUserTypeClassInst:
    result = mapTypeToAst(t.lastSon, info)
  of tyDistinct:
    if inst:
      result = newNodeX(nkDistinctTy)
      result.add mapTypeToAst(t.sons[0], info)
    else:
      if allowRecursion or t.sym==nil:
        result = mapTypeToBracket("distinct", t, info)
      else:
        result = atomicType(t.sym.name.s)
  of tyGenericParam, tyForward: result = atomicType(t.sym.name.s)
  of tyObject:
    if inst:
      result = newNodeX(nkObjectTy)
      result.add ast.emptyNode  # pragmas not reconstructed yet
      if t.sons[0]==nil: result.add ast.emptyNode  # handle parent object
      else:
        var nn = newNodeX(nkOfInherit)
        nn.add mapTypeToAst(t.sons[0], info)
        result.add nn
      if t.n.sons.len>0:
        var rl = copyNode(t.n)  # handle nkRecList
        for s in t.n.sons:
          rl.add newIdentDefs(s)
        result.add rl
      else:
        result.add ast.emptyNode
    else:
      if allowRecursion or t.sym == nil:
        result = newNodeIT(nkObjectTy, if t.n.isNil: info else: t.n.info, t)
        result.add ast.emptyNode
        if t.sons[0] == nil:
          result.add ast.emptyNode
        else:
          result.add mapTypeToAst(t.sons[0], info)
        result.add copyTree(t.n)
      else:
        result = atomicType(t.sym.name.s)
  of tyEnum:
    result = newNodeIT(nkEnumTy, if t.n.isNil: info else: t.n.info, t)
    result.add copyTree(t.n)
  of tyTuple:
    if inst:
      result = newNodeX(nkTupleTy)
      for s in t.n.sons:
        result.add newIdentDefs(s)
    else:
      result = mapTypeToBracket("tuple", t, info)
  of tySet: result = mapTypeToBracket("set", t, info)
  of tyPtr:
    if inst:
      result = newNodeX(nkPtrTy)
      result.add mapTypeToAst(t.sons[0], info)
    else:
      result = mapTypeToBracket("ptr", t, info)
  of tyRef:
    if inst:
      result = newNodeX(nkRefTy)
      result.add mapTypeToAst(t.sons[0], info)
    else:
      result = mapTypeToBracket("ref", t, info)
  of tyVar: result = mapTypeToBracket("var", t, info)
  of tySequence: result = mapTypeToBracket("seq", t, info)
  of tyProc:
    if inst:
      result = newNodeX(nkProcTy)
      var fp = newNodeX(nkFormalParams)
      if t.sons[0] == nil:
        fp.add ast.emptyNode
      else:
        fp.add mapTypeToAst(t.sons[0], t.n[0].info)
      for i in 1..<t.sons.len:
        fp.add newIdentDefs(t.n[i], t.sons[i])
      result.add fp
      result.add ast.emptyNode  # pragmas aren't reconstructed yet
    else:
      result = mapTypeToBracket("proc", t, info)
  of tyOpenArray: result = mapTypeToBracket("openArray", t, info)
  of tyRange:
    result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
    result.add atomicType("range")
    result.add t.n.sons[0].copyTree
    result.add t.n.sons[1].copyTree
  of tyPointer: result = atomicType"pointer"
  of tyString: result = atomicType"string"
  of tyCString: result = atomicType"cstring"
  of tyInt: result = atomicType"int"
  of tyInt8: result = atomicType"int8"
  of tyInt16: result = atomicType"int16"
  of tyInt32: result = atomicType"int32"
  of tyInt64: result = atomicType"int64"
  of tyFloat: result = atomicType"float"
  of tyFloat32: result = atomicType"float32"
  of tyFloat64: result = atomicType"float64"
  of tyFloat128: result = atomicType"float128"
  of tyUInt: result = atomicType"uint"
  of tyUInt8: result = atomicType"uint8"
  of tyUInt16: result = atomicType"uint16"
  of tyUInt32: result = atomicType"uint32"
  of tyUInt64: result = atomicType"uint64"
  of tyBigNum: result = atomicType"bignum"
  of tyConst: result = mapTypeToBracket("const", t, info)
  of tyMutable: result = mapTypeToBracket("mutable", t, info)
  of tyVarargs: result = mapTypeToBracket("varargs", t, info)
  of tyIter: result = mapTypeToBracket("iter", t, info)
  of tyProxy: result = atomicType"error"
  of tyBuiltInTypeClass: result = mapTypeToBracket("builtinTypeClass", t, info)
  of tyUserTypeClass:
    result = mapTypeToBracket("concept", t, info)
    result.add t.n.copyTree
  of tyCompositeTypeClass: result = mapTypeToBracket("compositeTypeClass", t, info)
  of tyAnd: result = mapTypeToBracket("and", t, info)
  of tyOr: result = mapTypeToBracket("or", t, info)
  of tyNot: result = mapTypeToBracket("not", t, info)
  of tyAnything: result = atomicType"anything"
  of tyStatic, tyFromExpr, tyFieldAccessor:
    if inst:
      if t.n != nil: result = t.n.copyTree
      else: result = atomicType "void"
    else:
      result = newNodeIT(nkBracketExpr, if t.n.isNil: info else: t.n.info, t)
      result.add atomicType "static"
      if t.n != nil:
        result.add t.n.copyTree

proc opMapTypeToAst*(t: PType; info: TLineInfo): PNode =
  result = mapTypeToAstX(t, info, false, true)

# the "Inst" version includes generic parameters in the resulting type tree
# and also tries to look like the corresponding Nim type declaration
proc opMapTypeInstToAst*(t: PType; info: TLineInfo): PNode =
  result = mapTypeToAstX(t, info, true, false)

# the "Impl" version includes generic parameters in the resulting type tree
# and also tries to look like the corresponding Nim type implementation
proc opMapTypeImplToAst*(t: PType; info: TLineInfo): PNode =
  result = mapTypeToAstX(t, info, true, true)
