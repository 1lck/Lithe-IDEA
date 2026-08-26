import Foundation

public struct BundledLanguagePluginSpecification: Sendable {
    public let id: String
    public let displayName: String
    public let fileExtensions: [String]
    public let fileNames: [String]
    public let executableNames: [String]
    public let arguments: [String]
    public let validationArguments: [String]
    public let languageIdentifier: String
    public let supportsExecution: Bool

    public init(
        id: String,
        displayName: String,
        fileExtensions: [String],
        fileNames: [String] = [],
        executableNames: [String] = [],
        arguments: [String] = [],
        validationArguments: [String] = [],
        languageIdentifier: String? = nil,
        supportsExecution: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.executableNames = executableNames
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.languageIdentifier = languageIdentifier ?? id
        self.supportsExecution = supportsExecution
    }
}

/// Non-Java language providers are independently manageable bundled plugins.
/// Go remains an official native package and is therefore not duplicated here.
public enum BundledLanguagePluginCatalog {
    public static let specifications: [BundledLanguagePluginSpecification] = [
        .init(id: "python", displayName: "Python", fileExtensions: ["py", "pyw"], executableNames: ["basedpyright-langserver", "pyright-langserver"], arguments: ["--stdio"], supportsExecution: true),
        .init(id: "node", displayName: "Node.js", fileExtensions: ["js", "jsx", "ts", "tsx", "mjs", "cjs"], executableNames: ["typescript-language-server"], arguments: ["--stdio"], languageIdentifier: "javascript", supportsExecution: true),
        .init(id: "rust", displayName: "Rust", fileExtensions: ["rs"], executableNames: ["rust-analyzer"], validationArguments: ["--version"], supportsExecution: true),
        .init(id: "clangd", displayName: "C/C++/Objective-C", fileExtensions: ["c", "h", "hh", "hpp", "hxx", "cpp", "cc", "cxx", "m", "mm"], executableNames: ["clangd"], languageIdentifier: "cpp"),
        .init(id: "csharp", displayName: "C#", fileExtensions: ["cs", "csx"]),
        .init(id: "fsharp", displayName: "F#", fileExtensions: ["fs", "fsi", "fsx"]),
        .init(id: "swift", displayName: "Swift", fileExtensions: ["swift"], executableNames: ["sourcekit-lsp"]),
        .init(id: "kotlin", displayName: "Kotlin", fileExtensions: ["kt", "kts"], executableNames: ["kotlin-language-server"]),
        .init(id: "scala", displayName: "Scala", fileExtensions: ["scala", "sc"], executableNames: ["metals"]),
        .init(id: "groovy", displayName: "Groovy", fileExtensions: ["groovy"]),
        .init(id: "ruby", displayName: "Ruby", fileExtensions: ["rb", "rake", "gemspec"], fileNames: ["Rakefile", "Gemfile"], executableNames: ["ruby-lsp"]),
        .init(id: "php", displayName: "PHP", fileExtensions: ["php", "phtml"], executableNames: ["intelephense", "phpactor"]),
        .init(id: "dart", displayName: "Dart", fileExtensions: ["dart"]),
        .init(id: "lua", displayName: "Lua", fileExtensions: ["lua"]),
        .init(id: "shell", displayName: "Shell", fileExtensions: ["sh", "bash", "zsh", "fish", "ksh"], executableNames: ["bash-language-server"], arguments: ["start"], languageIdentifier: "shellscript"),
        .init(id: "powershell", displayName: "PowerShell", fileExtensions: ["ps1", "psm1", "psd1"]),
        .init(id: "html", displayName: "HTML", fileExtensions: ["html", "htm", "xhtml"]),
        .init(id: "css", displayName: "CSS", fileExtensions: ["css", "scss", "sass", "less"]),
        .init(id: "vue", displayName: "Vue", fileExtensions: ["vue"]),
        .init(id: "svelte", displayName: "Svelte", fileExtensions: ["svelte"]),
        .init(id: "astro", displayName: "Astro", fileExtensions: ["astro"]),
        .init(id: "json", displayName: "JSON", fileExtensions: ["json", "jsonc", "json5"]),
        .init(id: "yaml", displayName: "YAML", fileExtensions: ["yml", "yaml"], executableNames: ["yaml-language-server"], arguments: ["--stdio"]),
        .init(id: "xml", displayName: "XML", fileExtensions: ["xml", "xsd", "wsdl", "pom"]),
        .init(id: "markdown", displayName: "Markdown", fileExtensions: ["md", "markdown", "mdx"]),
        .init(id: "sql", displayName: "SQL", fileExtensions: ["sql"]),
        .init(id: "terraform", displayName: "Terraform", fileExtensions: ["tf", "tfvars"]),
        .init(id: "dockerfile", displayName: "Dockerfile", fileExtensions: ["dockerfile"], fileNames: ["Dockerfile"]),
        .init(id: "cmake", displayName: "CMake", fileExtensions: ["cmake"], fileNames: ["CMakeLists.txt"]),
        .init(id: "make", displayName: "Make", fileExtensions: ["mk"], fileNames: ["Makefile", "GNUmakefile"]),
        .init(id: "toml", displayName: "TOML", fileExtensions: ["toml"]),
        .init(id: "graphql", displayName: "GraphQL", fileExtensions: ["graphql", "gql"]),
        .init(id: "protobuf", displayName: "Protocol Buffers", fileExtensions: ["proto"]),
        .init(id: "prisma", displayName: "Prisma", fileExtensions: ["prisma"]),
        .init(id: "elixir", displayName: "Elixir", fileExtensions: ["ex", "exs"]),
        .init(id: "erlang", displayName: "Erlang", fileExtensions: ["erl", "hrl"]),
        .init(id: "haskell", displayName: "Haskell", fileExtensions: ["hs", "lhs"]),
        .init(id: "ocaml", displayName: "OCaml", fileExtensions: ["ml", "mli"]),
        .init(id: "clojure", displayName: "Clojure", fileExtensions: ["clj", "cljs", "cljc", "edn"]),
        .init(id: "julia", displayName: "Julia", fileExtensions: ["jl"]),
        .init(id: "r", displayName: "R", fileExtensions: ["r"]),
        .init(id: "perl", displayName: "Perl", fileExtensions: ["pl", "pm", "t"]),
        .init(id: "zig", displayName: "Zig", fileExtensions: ["zig"]),
        .init(id: "solidity", displayName: "Solidity", fileExtensions: ["sol"])
    ]

    public static let manifests: [PluginManifest] = specifications.map(makeManifest).sorted { $0.id < $1.id }

    public static func specification(languageID: String) -> BundledLanguagePluginSpecification? {
        specifications.first { $0.id == languageID }
    }

    private static func makeManifest(_ specification: BundledLanguagePluginSpecification) -> PluginManifest {
        var modules = [PluginModuleDeclaration(manifest: languageServerManifest(specification))]
        if specification.supportsExecution {
            modules.append(PluginModuleDeclaration(manifest: executionManifest(specification)))
        }
        return PluginManifest(
            id: PluginID("dev.lithe.plugin.\(specification.id)-support"),
            displayName: "\(specification.displayName) Support",
            version: BuiltInPluginCatalog.hostVersion,
            hostCompatibility: PluginHostCompatibility(
                minimum: BuiltInPluginCatalog.hostVersion,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: BuiltInPluginCatalog.vendor,
            entrypoint: .builtIn(targetName: "LitheLanguageSupportModules"),
            modules: modules,
            languageSupports: [LanguageSupportDeclaration(
                id: specification.id,
                displayName: specification.displayName,
                fileExtensions: specification.fileExtensions,
                fileNames: specification.fileNames,
                languageServerModuleID: .languageServerExtension(specification.id),
                executionModuleID: specification.supportsExecution ? .languageExecutionExtension(specification.id) : nil,
                testingModuleID: specification.supportsExecution ? .languageExecutionExtension(specification.id) : nil
            )]
        )
    }

    private static func languageServerManifest(_ specification: BundledLanguagePluginSpecification) -> ModuleManifest {
        ModuleManifest(
            id: .languageServerExtension(specification.id),
            displayName: "\(specification.displayName) Language Server",
            scope: .workspace,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.languageServerExtension(specification.id)]
        )
    }

    private static func executionManifest(_ specification: BundledLanguagePluginSpecification) -> ModuleManifest {
        ModuleManifest(
            id: .languageExecutionExtension(specification.id),
            displayName: "\(specification.displayName) Execution",
            scope: .workspace,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [
                .languageExecutionExtension(specification.id),
                .languageTestingExtension(specification.id)
            ]
        )
    }
}
