use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs::{self, File};
use std::io::Write;

#[test]
fn spring_index_links_configuration_profiles_beans_and_endpoints() {
    let root = temporary_root("spring-index");
    let java = root.join("src/main/java/demo");
    let resources = root.join("src/main/resources");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::create_dir_all(resources.join("META-INF"))
        .expect("resource fixture directory should be creatable");
    fs::write(
        java.join("DemoProperties.java"),
        r#"package demo;
@ConfigurationProperties(prefix = "demo")
public class DemoProperties {
  private boolean enabled;
  private int retryCount;
  private Security security;
  public static class Security {
    private java.time.Duration timeout;
  }
}
"#,
    )
    .expect("configuration properties fixture should be writable");
    fs::write(
        java.join("RecordProperties.java"),
        r#"package demo;
@ConfigurationProperties(prefix = "recorded")
public record RecordProperties(boolean enabled, int retryCount) {}
"#,
    )
    .expect("record configuration properties fixture should be writable");
    fs::write(
        java.join("GreetingService.java"),
        "package demo;\n@Service\npublic class GreetingService {}\n",
    )
    .expect("service fixture should be writable");
    fs::write(
        java.join("GreetingController.java"),
        r#"package demo;
@RestController
@RequestMapping("/api")
public class GreetingController {
  @Autowired
  private GreetingService service;
  @GetMapping("/greet")
  public String greet() { return "hi"; }
}
"#,
    )
    .expect("controller fixture should be writable");
    fs::write(
        resources.join("application.yml"),
        "demo:\n  enabled: true\n  retry-count: 3\n",
    )
    .expect("base configuration fixture should be writable");
    fs::write(
        resources.join("application-dev.yml"),
        "demo:\n  retry-count: nope\n",
    )
    .expect("profile configuration fixture should be writable");
    fs::write(
        resources.join("META-INF/spring-configuration-metadata.json"),
        r#"{"properties":[{"name":"demo.title","type":"java.lang.String","description":"Display title."}]}"#,
    )
    .expect("metadata fixture should be writable");

    let paths = [
        "src/main/java/demo/DemoProperties.java",
        "src/main/java/demo/RecordProperties.java",
        "src/main/java/demo/GreetingService.java",
        "src/main/java/demo/GreetingController.java",
        "src/main/resources/application.yml",
        "src/main/resources/application-dev.yml",
        "src/main/resources/META-INF/spring-configuration-metadata.json",
    ];
    let response = execute_spring(&root, &paths, serde_json::json!({}));

    assert_eq!(response["ok"], true, "{response}");
    let properties = response["data"]["properties"].as_array().unwrap();
    assert!(properties
        .iter()
        .any(|value| value["name"] == "demo.retry-count"));
    assert!(properties.iter().any(|value| value["name"] == "demo.title"));
    assert!(properties
        .iter()
        .any(|value| value["name"] == "demo.security.timeout"));
    assert!(properties
        .iter()
        .any(|value| value["name"] == "recorded.retry-count"));
    let profile_value = response["data"]["values"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["path"].as_str().unwrap().contains("application-dev"))
        .unwrap();
    assert_eq!(profile_value["profile"], "dev");
    assert_eq!(profile_value["overridesBaseValue"], true);
    assert!(profile_value["targetPath"]
        .as_str()
        .unwrap()
        .ends_with("DemoProperties.java"));
    assert!(response["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["severity"] == "error"));
    assert!(response["data"]["beans"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["typeName"] == "GreetingService"));
    assert!(
        response["data"]["injections"][0]["beanIds"]
            .as_array()
            .unwrap()
            .len()
            == 1,
        "{response}"
    );
    assert_eq!(response["data"]["endpoints"][0]["route"], "/api/greet");
    assert_eq!(response["data"]["endpoints"][0]["httpMethods"][0], "GET");

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

#[test]
fn spring_index_resolves_qualifiers_primary_interfaces_and_constructors() {
    let root = temporary_root("spring-injection");
    let java = root.join("src/main/java/demo");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::write(
        java.join("PaymentService.java"),
        "package demo;\npublic interface PaymentService {}\n",
    )
    .expect("interface fixture should be writable");
    fs::write(
        java.join("StripePaymentService.java"),
        r#"package demo;
@Service("stripe")
public class StripePaymentService implements PaymentService {}
"#,
    )
    .expect("qualified service fixture should be writable");
    fs::write(
        java.join("PaypalPaymentService.java"),
        r#"package demo;
@Service
@Primary
public class PaypalPaymentService implements PaymentService {}
"#,
    )
    .expect("primary service fixture should be writable");
    fs::write(
        java.join("CheckoutController.java"),
        r#"package demo;
@RestController
public class CheckoutController {
  private final PaymentService paymentService;
  public CheckoutController(@Qualifier("stripe") PaymentService paymentService) {
    this.paymentService = paymentService;
  }
}
"#,
    )
    .expect("qualified constructor fixture should be writable");
    fs::write(
        java.join("ReportController.java"),
        r#"package demo;
@Controller
public class ReportController {
  public ReportController(PaymentService paymentService) {}
}
"#,
    )
    .expect("primary constructor fixture should be writable");

    let paths = [
        "src/main/java/demo/PaymentService.java",
        "src/main/java/demo/StripePaymentService.java",
        "src/main/java/demo/PaypalPaymentService.java",
        "src/main/java/demo/CheckoutController.java",
        "src/main/java/demo/ReportController.java",
    ];
    let response = execute_spring(&root, &paths, serde_json::json!({}));
    assert_eq!(response["ok"], true, "{response}");
    let injections = response["data"]["injections"].as_array().unwrap();
    let qualified = injections
        .iter()
        .find(|value| {
            value["path"]
                .as_str()
                .unwrap()
                .contains("CheckoutController")
        })
        .unwrap_or_else(|| panic!("missing qualified injection: {response}"));
    assert_eq!(qualified["qualifier"], "stripe");
    assert_eq!(qualified["beanIds"].as_array().unwrap().len(), 1);
    assert!(qualified["beanIds"][0].as_str().unwrap().contains("stripe"));
    let primary = injections
        .iter()
        .find(|value| value["path"].as_str().unwrap().contains("ReportController"))
        .unwrap();
    assert_eq!(primary["beanIds"].as_array().unwrap().len(), 1);
    assert!(primary["beanIds"][0]
        .as_str()
        .unwrap()
        .contains("paypalPaymentService"));
    assert!(response["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .is_empty());

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

#[test]
fn spring_index_links_value_references_profiles_and_mapping_variants() {
    let root = temporary_root("spring-web-config");
    let java = root.join("src/main/java/demo");
    let resources = root.join("src/main/resources/META-INF");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::create_dir_all(&resources).expect("resource fixture directory should be creatable");
    fs::write(
        java.join("ApiController.java"),
        r#"package demo;
@RestController
@RequestMapping(path = {"/api", "/v2"})
public class ApiController {
  @Value("${demo.retryCount:3}")
  private int retryCount;
  @GetMapping(path = {"/a", "/b"})
  public String get() { return "ok"; }
  @RequestMapping(path = "/multi", method = {RequestMethod.GET, RequestMethod.POST})
  public String multi() { return "ok"; }
}
"#,
    )
    .expect("controller fixture should be writable");
    fs::write(
        root.join("src/main/resources/application.yml"),
        "demo:\n  retryCount: 2\n---\ndemo:\n  retry-count:\n    - 3\nspring:\n  config:\n    activate:\n      on-profile: dev\n",
    )
    .expect("multi-document YAML fixture should be writable");
    fs::write(
        resources.join("spring-configuration-metadata.json"),
        r#"{"properties":[{"name":"demo.retry-count","type":"java.lang.Integer"}]}"#,
    )
    .expect("metadata fixture should be writable");

    let paths = [
        "src/main/java/demo/ApiController.java",
        "src/main/resources/application.yml",
        "src/main/resources/META-INF/spring-configuration-metadata.json",
    ];
    let response = execute_spring(&root, &paths, serde_json::json!({}));
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["propertyReferences"][0]["key"],
        "demo.retry-count"
    );
    let values = response["data"]["values"].as_array().unwrap();
    assert!(values
        .iter()
        .any(|value| { value["key"] == "demo.retry-count" && value["profile"] == "dev" }));
    assert!(!response["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["message"].as_str().unwrap().contains("Unknown")));
    let endpoints = response["data"]["endpoints"].as_array().unwrap();
    assert_eq!(
        endpoints
            .iter()
            .filter(|value| value["route"].as_str().unwrap().ends_with("/a"))
            .count(),
        2
    );
    assert!(endpoints.iter().any(|value| {
        value["route"] == "/api/multi" && value["httpMethods"] == serde_json::json!(["GET", "POST"])
    }));

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

/// Annotation detection matches `@Name` only when the name ends at whitespace,
/// an argument list, or the end of the context. Caching the compiled patterns
/// must not turn a prefix such as `@Bean` into a match for `@BeanFactory`.
#[test]
fn spring_index_does_not_treat_longer_annotations_as_recognized_ones() {
    let root = temporary_root("spring-annotation-boundary");
    let java = root.join("src/main/java/demo");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::write(
        java.join("RealConfig.java"),
        r#"package demo;
@Configuration
public class RealConfig {
  @Bean
  public Clock clock() { return null; }
  @BeanFactory
  public Clock decoyClock() { return null; }
}
"#,
    )
    .expect("configuration fixture should be writable");
    fs::write(
        java.join("DecoyService.java"),
        "package demo;\n@ServiceLocator\npublic class DecoyService {}\n",
    )
    .expect("decoy fixture should be writable");
    fs::write(
        java.join("DecoyController.java"),
        "package demo;\n@RestControllerAdvice\npublic class DecoyController {\n  @GetMapping(\"/decoy\")\n  public String decoy() { return \"\"; }\n}\n",
    )
    .expect("decoy controller fixture should be writable");

    let paths = [
        "src/main/java/demo/RealConfig.java",
        "src/main/java/demo/DecoyService.java",
        "src/main/java/demo/DecoyController.java",
    ];
    let response = execute_spring(&root, &paths, serde_json::json!({}));
    assert_eq!(response["ok"], true, "{response}");

    let beans = response["data"]["beans"].as_array().unwrap();
    let names = beans
        .iter()
        .map(|value| value["name"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(names.contains(&"clock"), "{response}");
    assert!(names.contains(&"realConfig"), "{response}");
    assert!(!names.contains(&"decoyClock"), "{response}");
    assert!(!names.contains(&"decoyService"), "{response}");

    // @RestControllerAdvice is not @RestController, so no route is collected.
    assert!(
        response["data"]["endpoints"].as_array().unwrap().is_empty(),
        "{response}"
    );

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

/// Custom annotations that only share a Mapping prefix must not become
/// endpoints or class-level base routes; exact Spring Mapping names still do.
#[test]
fn spring_index_ignores_mapping_annotations_that_only_share_a_prefix() {
    let root = temporary_root("spring-mapping-prefix");
    let java = root.join("src/main/java/demo");
    fs::create_dir_all(&java).expect("Java fixture directory should be creatable");
    fs::write(
        java.join("DemoController.java"),
        r#"package demo;
@RestController
@RequestMappingFoo("/base")
public class DemoController {
  @GetMappingCustom("/x")
  public String custom() { return ""; }
  @PostMappingCustom("/post")
  public String postCustom() { return ""; }
  @PutMappingCustom("/put")
  public String putCustom() { return ""; }
  @DeleteMappingCustom("/delete")
  public String deleteCustom() { return ""; }
  @PatchMappingCustom("/patch")
  public String patchCustom() { return ""; }
  @GetMapping("/real")
  public String real() { return ""; }
}
"#,
    )
    .expect("controller fixture should be writable");

    let response = execute_spring(
        &root,
        &["src/main/java/demo/DemoController.java"],
        serde_json::json!({}),
    );
    assert_eq!(response["ok"], true, "{response}");

    let endpoints = response["data"]["endpoints"].as_array().unwrap();
    assert_eq!(endpoints.len(), 1, "{response}");
    assert_eq!(endpoints[0]["route"], "/real");
    assert_eq!(endpoints[0]["httpMethods"][0], "GET");
    assert_eq!(endpoints[0]["method"], "real");

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

#[test]
fn spring_dependency_metadata_cache_refresh_is_explicit() {
    let root = temporary_root("spring-metadata-cache");
    let repository = root.join("repository");
    fs::create_dir_all(&repository).expect("metadata repository should be creatable");
    let archive = repository.join("fixture.jar");
    write_metadata_archive(&archive, "cache.first");

    let refreshed = execute_spring(
        &root,
        &[],
        serde_json::json!({
            "metadataRepository": repository,
            "refreshDependencyMetadata": true
        }),
    );
    assert!(has_property(&refreshed, "cache.first"));
    write_metadata_archive(&archive, "cache.second");
    let cached = execute_spring(
        &root,
        &[],
        serde_json::json!({"metadataRepository": repository}),
    );
    assert!(has_property(&cached, "cache.first"));
    assert!(!has_property(&cached, "cache.second"));
    let refreshed = execute_spring(
        &root,
        &[],
        serde_json::json!({
            "metadataRepository": repository,
            "refreshDependencyMetadata": true
        }),
    );
    assert!(has_property(&refreshed, "cache.second"));

    fs::remove_dir_all(root).expect("Spring fixture should be removable");
}

fn execute_spring(root: &std::path::Path, paths: &[&str], extra: Value) -> Value {
    let mut payload = serde_json::json!({"root": root, "paths": paths});
    payload
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().cloned().unwrap_or_default());
    let request = serde_json::json!({
        "id": "spring",
        "command": "spring.index",
        "payload": payload
    });
    serde_json::from_str(&execute_json(&request.to_string()))
        .expect("Spring response should be JSON")
}

fn write_metadata_archive(path: &std::path::Path, property: &str) {
    let file = File::create(path).expect("metadata archive should be creatable");
    let mut archive = zip::ZipWriter::new(file);
    archive
        .start_file(
            "META-INF/spring-configuration-metadata.json",
            zip::write::SimpleFileOptions::default(),
        )
        .expect("metadata entry should be creatable");
    write!(archive, r#"{{"properties":[{{"name":"{property}"}}]}}"#)
        .expect("metadata should be writable");
    archive.finish().expect("metadata archive should close");
}

fn has_property(response: &Value, name: &str) -> bool {
    response["data"]["properties"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["name"] == name)
}
