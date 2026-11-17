//go:build vivahead && lithevisual

package workbench

import (
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// bundledGrammarSamples are one short file of every language whose grammar the editor bundles
// for #2112, in the order the contact sheet lays them out. The first line names the language.
var bundledGrammarSamples = []struct{ name, source string }{
	{"order.py", "# Python\nfrom dataclasses import dataclass\n\n@dataclass\nclass Order(Base):\n    price: int = 0\n\n    def total(self, count: int) -> int:\n        \"\"\"Price of count items.\"\"\"\n        return self.price * count if count > 0 else None\n"},
	{"deploy.sh", "#!/usr/bin/env bash\n# Shell\nset -euo pipefail\nNAME=\"${1:-lithe}\"\nfor f in ./dist/*.tar.gz; do\n  echo \"Uploading $f for $NAME\" | tee -a log.txt\ndone\n[[ -n \"$NAME\" ]] && exit 0\n"},
	{"Order.kt", "// Kotlin\npackage shop\n\ndata class Order(val name: String, val price: Int = 0) {\n    fun total(count: Int): Int = price * count\n\n    override fun toString() = \"Order $name: ${total(2)}\"\n}\n"},
	{"Greeter.groovy", "// Groovy\nclass Greeter extends Base {\n    def pattern = /\\d+/\n\n    String greet(String name) {\n        def count = 3\n        return \"Hello, ${name} x $count\"\n    }\n}\n"},
	{"CMakeLists.txt", "# CMake\ncmake_minimum_required(VERSION 3.20)\nproject(Demo LANGUAGES CXX)\nset(CMAKE_CXX_STANDARD 20)\nadd_executable(demo src/main.cpp)\nif(WIN32)\n  target_compile_definitions(demo PRIVATE USE_WIN=1)\nendif()\n"},
	{"Dockerfile", "# Dockerfile\nFROM golang:1.22 AS build\nWORKDIR /src\nCOPY . .\nRUN go build -o /out/app ./cmd/app\n\nFROM gcr.io/distroless/base\nENV PORT=8080\nEXPOSE 8080\nENTRYPOINT [\"/app\"]\n"},
	{"query.sql", "-- SQL\nCREATE TABLE orders (\n  id INTEGER PRIMARY KEY,\n  name VARCHAR(64) NOT NULL,\n  price DECIMAL(10, 2) DEFAULT 0\n);\nSELECT name, COUNT(*) AS total\nFROM orders WHERE price > 10.5\nGROUP BY name ORDER BY total DESC;\n"},
	{"index.php", "<!-- PHP -->\n<ul class=\"orders\">\n<?php foreach ($orders as $o): ?>\n  <li title=\"<?= $o->name ?>\"><?= total($o) ?> &amp;</li>\n<?php endforeach; ?>\n</ul>\n<?php\nfunction total(array $items): int {\n    return count($items) * 2; // items\n}\n"},
	{"order.rb", "# Ruby\nclass Order < Base\n  attr_reader :name, :price\n\n  def initialize(name, price = 0)\n    @name = name\n    @price = price\n  end\n\n  def label\n    \"#{@name}: #{price}\" unless price.nil?\n  end\nend\n"},
	{"Order.swift", "// Swift\nimport Foundation\n\nstruct Order: Codable {\n    let name: String\n    var price: Int = 0\n\n    func total(_ count: Int) -> Int {\n        return price * count\n    }\n}\n"},
	{"Order.cs", "// C#\nusing System;\n\npublic class Order : Base\n{\n    public string Name { get; init; } = \"\";\n    public int Total(int count) => count > 0 ? Price * count : 0;\n    public override string ToString() => $\"Order {Name}\";\n}\n"},
	{"order.lua", "-- Lua\nlocal Order = {}\nOrder.__index = Order\n\nfunction Order.new(name, price)\n  local self = setmetatable({}, Order)\n  self.name, self.price = name, price or 0\n  return self\nend\n"},
	{"deploy.ps1", "# PowerShell\nparam([string]$Name = \"lithe\")\n$files = Get-ChildItem -Path ./dist -Filter *.zip\nforeach ($f in $files) {\n    if ($f.Length -gt 0 -and $true) {\n        Write-Host \"Uploading $($f.Name) for $Name\"\n    }\n}\n"},
	{"main.zig", "// Zig\nconst std = @import(\"std\");\n\npub fn main() !void {\n    const stdout = std.io.getStdOut().writer();\n    var total: u32 = 0;\n    for (0..10) |i| total += @intCast(i);\n    try stdout.print(\"total: {d}\\n\", .{total});\n}\n"},
	{"order.proto", "// Protobuf\nsyntax = \"proto3\";\npackage shop;\n\nmessage Order {\n  string name = 1;\n  int32 price = 2;\n  repeated string tags = 3;\n}\n\nservice Orders { rpc Get(Order) returns (Order); }\n"},
	{"Order.m", "// Objective-C\n#import <Foundation/Foundation.h>\n\n@interface Order : NSObject\n@property (nonatomic, copy) NSString *name;\n@end\n\n@implementation Order\n- (NSInteger)total:(NSInteger)count { return count * 2; }\n@end\n"},
	{"Bridge.mm", "// Objective-C++\n#import <Foundation/Foundation.h>\n#include <vector>\n\n@implementation Bridge\n- (NSUInteger)count {\n    std::vector<int> items{1, 2, 3};\n    return static_cast<NSUInteger>(items.size());\n}\n@end\n"},
	{"Makefile", "# Makefile\nGO ?= go\nBIN := bin/app\n\n.PHONY: build test\nbuild: $(BIN)\n$(BIN): $(wildcard *.go)\n\t$(GO) build -o $@ ./cmd/app\ntest:\n\t$(GO) test ./... -count=1\n"},
	{"schema.graphql", "# GraphQL\ntype Order {\n  id: ID!\n  name: String!\n  price: Int @deprecated(reason: \"Use total\")\n}\n\nquery Orders($first: Int = 10) {\n  orders(first: $first) { id name }\n}\n"},
}

// TestVisualBundledGrammars captures each sample of bundledGrammarSamples in the editor and lays
// the top left of the editors out in one contact sheet per theme, grammars-<theme>.png, beside
// the whole window of the PHP sample, grammars-php-<theme>.png. The same test on a revision
// without the grammars shows what they change. It needs only LITHE_VISUAL_OUTPUT_DIR.
func TestVisualBundledGrammars(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	const width, height = 1440, 900
	// A tile is the editor's top left, in points: the gutter and the longest sample line, and
	// the most lines a sample has.
	const tileWidth, tileHeight, columns, gap = 600, 290, 4, 2
	for _, look := range []struct{ theme, language string }{{"dark", "zh-Hans"}, {"light", "en"}} {
		t.Run(look.theme, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(t.TempDir(), "GrammarsDemo")
			if err := os.MkdirAll(root, 0700); err != nil {
				t.Fatal(err)
			}
			for _, sample := range bundledGrammarSamples {
				if err := os.WriteFile(filepath.Join(root, sample.name), []byte(sample.source), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language}}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = width, height
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.open(root)
			p := h.app.project
			var sheet *image.RGBA
			for index, sample := range bundledGrammarSamples {
				path := filepath.Join(root, sample.name)
				h.app.openFile(p, path)
				h.settleChain()
				d := p.docs.byPath(path)
				if d == nil {
					t.Fatalf("%s did not open", sample.name)
				}
				h.app.invalidator.Invalidate()
				h.settleChain()
				frame, err := session.Image()
				if err != nil {
					t.Fatal(err)
				}
				scale := float64(frame.Bounds().Dx()) / width
				editor := h.topHit(d.hit)
				px := func(points float64) int { return int(points*scale + 0.5) }
				tile := image.Rect(px(float64(editor.X)), px(float64(editor.Y)), px(float64(editor.X)+tileWidth), px(float64(editor.Y)+tileHeight))
				if !tile.In(frame.Bounds()) {
					t.Fatalf("%s: the editor at %v is smaller than a tile", sample.name, editor)
				}
				if sheet == nil {
					rows := (len(bundledGrammarSamples) + columns - 1) / columns
					sheet = image.NewRGBA(image.Rect(0, 0, columns*tile.Dx()+(columns-1)*px(gap), rows*tile.Dy()+(rows-1)*px(gap)))
					draw.Draw(sheet, sheet.Bounds(), image.NewUniform(color.Gray{Y: 0x80}), image.Point{}, draw.Src)
				}
				at := image.Pt(index%columns*(tile.Dx()+px(gap)), index/columns*(tile.Dy()+px(gap)))
				draw.Draw(sheet, image.Rectangle{Min: at, Max: at.Add(tile.Size())}, frame, tile.Min, draw.Src)
				if sample.name == "index.php" {
					if err := session.Screenshot(filepath.Join(out, "grammars-php-"+look.theme+".png")); err != nil {
						t.Fatal(err)
					}
				}
			}
			file, err := os.Create(filepath.Join(out, "grammars-"+look.theme+".png"))
			if err != nil {
				t.Fatal(err)
			}
			defer file.Close()
			if err := png.Encode(file, sheet); err != nil {
				t.Fatal(err)
			}
		})
	}
}
