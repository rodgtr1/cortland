// Generated: tree-sitter highlight queries embedded as raw-string literals
// (build-app.sh packages only binaries, so resource bundles would be absent).
// Sources: tree-sitter/{go,rust} and javascript+typescript (combined) highlights.scm.
// JS/JSX/TS/TSX are all highlighted via the TSX grammar (a superset), so the
// combined JS-base + TS-additions query compiles against it.
import Foundation

let tsQueryGo = #"""
; Function calls

(call_expression
  function: (identifier) @function)

(call_expression
  function: (identifier) @function.builtin
  (#match? @function.builtin "^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$"))

(call_expression
  function: (selector_expression
    field: (field_identifier) @function.method))

; Function definitions

(function_declaration
  name: (identifier) @function)

(method_declaration
  name: (field_identifier) @function.method)

; Identifiers

(type_identifier) @type
(field_identifier) @property
(identifier) @variable

; Operators

[
  "--"
  "-"
  "-="
  ":="
  "!"
  "!="
  "..."
  "*"
  "*"
  "*="
  "/"
  "/="
  "&"
  "&&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "++"
  "+="
  "<-"
  "<"
  "<<"
  "<<="
  "<="
  "="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "||"
  "~"
] @operator

; Keywords

[
  "break"
  "case"
  "chan"
  "const"
  "continue"
  "default"
  "defer"
  "else"
  "fallthrough"
  "for"
  "func"
  "go"
  "goto"
  "if"
  "import"
  "interface"
  "map"
  "package"
  "range"
  "return"
  "select"
  "struct"
  "switch"
  "type"
  "var"
] @keyword

; Literals

[
  (interpreted_string_literal)
  (raw_string_literal)
  (rune_literal)
] @string

(escape_sequence) @escape

[
  (int_literal)
  (float_literal)
  (imaginary_literal)
] @number

[
  (true)
  (false)
  (nil)
  (iota)
] @constant.builtin

(comment) @comment

"""#

let tsQueryRust = #"""
; Identifiers

(type_identifier) @type
(primitive_type) @type.builtin
(field_identifier) @property

; Identifier conventions

; Assume all-caps names are constants
((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]+$'"))

; Assume uppercase names are enum constructors
((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

; Assume that uppercase names in paths are types
((scoped_identifier
  path: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_identifier
  path: (scoped_identifier
    name: (identifier) @type))
 (#match? @type "^[A-Z]"))
((scoped_type_identifier
  path: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_type_identifier
  path: (scoped_identifier
    name: (identifier) @type))
 (#match? @type "^[A-Z]"))

; Assume all qualified names in struct patterns are enum constructors. (They're
; either that, or struct names; highlighting both as constructors seems to be
; the less glaring choice of error, visually.)
(struct_pattern
  type: (scoped_type_identifier
    name: (type_identifier) @constructor))

; Function calls

(call_expression
  function: (identifier) @function)
(call_expression
  function: (field_expression
    field: (field_identifier) @function.method))
(call_expression
  function: (scoped_identifier
    "::"
    name: (identifier) @function))

(generic_function
  function: (identifier) @function)
(generic_function
  function: (scoped_identifier
    name: (identifier) @function))
(generic_function
  function: (field_expression
    field: (field_identifier) @function.method))

(macro_invocation
  macro: (identifier) @function.macro
  "!" @function.macro)

; Function definitions

(function_item (identifier) @function)
(function_signature_item (identifier) @function)

(line_comment) @comment
(block_comment) @comment

(line_comment (doc_comment)) @comment.documentation
(block_comment (doc_comment)) @comment.documentation

"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)
(type_parameters
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

"::" @punctuation.delimiter
":" @punctuation.delimiter
"." @punctuation.delimiter
"," @punctuation.delimiter
";" @punctuation.delimiter

(parameter (identifier) @variable.parameter)

(lifetime (identifier) @label)

"as" @keyword
"async" @keyword
"await" @keyword
"break" @keyword
"const" @keyword
"continue" @keyword
"default" @keyword
"dyn" @keyword
"else" @keyword
"enum" @keyword
"extern" @keyword
"fn" @keyword
"for" @keyword
"gen" @keyword
"if" @keyword
"impl" @keyword
"in" @keyword
"let" @keyword
"loop" @keyword
"macro_rules!" @keyword
"match" @keyword
"mod" @keyword
"move" @keyword
"pub" @keyword
"raw" @keyword
"ref" @keyword
"return" @keyword
"static" @keyword
"struct" @keyword
"trait" @keyword
"type" @keyword
"union" @keyword
"unsafe" @keyword
"use" @keyword
"where" @keyword
"while" @keyword
"yield" @keyword
(crate) @keyword
(mutable_specifier) @keyword
(use_list (self) @keyword)
(scoped_use_list (self) @keyword)
(scoped_identifier (self) @keyword)
(super) @keyword

(self) @variable.builtin

(char_literal) @string
(string_literal) @string
(raw_string_literal) @string

(boolean_literal) @constant.builtin
(integer_literal) @constant.builtin
(float_literal) @constant.builtin

(escape_sequence) @escape

(attribute_item) @attribute
(inner_attribute_item) @attribute

"*" @operator
"&" @operator
"'" @operator

"""#

let tsQueryTypeScript = #"""
; Variables
;----------

(identifier) @variable

; Properties
;-----------

(property_identifier) @property

; Function and method definitions
;--------------------------------

(function_expression
  name: (identifier) @function)
(function_declaration
  name: (identifier) @function)
(method_definition
  name: (property_identifier) @function.method)

(pair
  key: (property_identifier) @function.method
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (member_expression
    property: (property_identifier) @function.method)
  right: [(function_expression) (arrow_function)])

(variable_declarator
  name: (identifier) @function
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (identifier) @function
  right: [(function_expression) (arrow_function)])

; Function and method calls
;--------------------------

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))

; Special identifiers
;--------------------

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

([
    (identifier)
    (shorthand_property_identifier)
    (shorthand_property_identifier_pattern)
 ] @constant
 (#match? @constant "^[A-Z_][A-Z\\d_]+$"))

((identifier) @variable.builtin
 (#match? @variable.builtin "^(arguments|module|console|window|document)$")
 (#is-not? local))

((identifier) @function.builtin
 (#eq? @function.builtin "require")
 (#is-not? local))

; Literals
;---------

(this) @variable.builtin
(super) @variable.builtin

[
  (true)
  (false)
  (null)
  (undefined)
] @constant.builtin

(comment) @comment

[
  (string)
  (template_string)
] @string

(regex) @string.special
(number) @number

; Tokens
;-------

[
  ";"
  (optional_chain)
  "."
  ","
] @punctuation.delimiter

[
  "-"
  "--"
  "-="
  "+"
  "++"
  "+="
  "*"
  "*="
  "**"
  "**="
  "/"
  "/="
  "%"
  "%="
  "<"
  "<="
  "<<"
  "<<="
  "="
  "=="
  "==="
  "!"
  "!="
  "!=="
  "=>"
  ">"
  ">="
  ">>"
  ">>="
  ">>>"
  ">>>="
  "~"
  "^"
  "&"
  "|"
  "^="
  "&="
  "|="
  "&&"
  "||"
  "??"
  "&&="
  "||="
  "??="
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
]  @punctuation.bracket

(template_substitution
  "${" @punctuation.special
  "}" @punctuation.special) @embedded

[
  "as"
  "async"
  "await"
  "break"
  "case"
  "catch"
  "class"
  "const"
  "continue"
  "debugger"
  "default"
  "delete"
  "do"
  "else"
  "export"
  "extends"
  "finally"
  "for"
  "from"
  "function"
  "get"
  "if"
  "import"
  "in"
  "instanceof"
  "let"
  "new"
  "of"
  "return"
  "set"
  "static"
  "switch"
  "target"
  "throw"
  "try"
  "typeof"
  "var"
  "void"
  "while"
  "with"
  "yield"
] @keyword

; Types

(type_identifier) @type
(predefined_type) @type.builtin

((identifier) @type
 (#match? @type "^[A-Z]"))

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; Variables

(required_parameter (identifier) @variable.parameter)
(optional_parameter (identifier) @variable.parameter)

; Keywords

[ "abstract"
  "declare"
  "enum"
  "export"
  "implements"
  "interface"
  "keyof"
  "namespace"
  "private"
  "protected"
  "public"
  "type"
  "readonly"
  "override"
  "satisfies"
] @keyword

"""#
