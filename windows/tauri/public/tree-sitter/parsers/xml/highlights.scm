(comment) @comment

(tag_name) @tag
(erroneous_end_tag_name) @tag

(doctype) @keyword
"<!" @keyword

(attribute_name) @attribute
(attribute_value) @string

(system_literal) @string
(pubid_literal) @string

(entity_ref) @constant
(char_ref) @constant

[
  "<"
  ">"
  "</"
  "/>"
  "<?"
  "?>"
] @punctuation.bracket

"=" @operator

(processing_instructions (tag_name) @keyword)

(cdata_start) @keyword
(cdata_end) @keyword

; Do not capture `(content)`: in nested markup (for example Maven pom.xml) that
; node spans child elements across many lines. Diff rendering concatenates token
; slices, so overlapping multi-line content tokens duplicate visible text.
