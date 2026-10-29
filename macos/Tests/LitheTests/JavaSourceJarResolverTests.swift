import Foundation
import Testing
@testable import Lithe

struct JavaSourceJarResolverTests {
    @Test
    func mapsJarClassURIToTopLevelSourceEntry() throws {
        let uri = try #require(URL(string: "jdt://contents/spring-jdbc-6.2.19.jar/org.springframework.jdbc.core/JdbcTemplate.class?=demo"))
        let target = try #require(JavaSourceJarResolver.SourceTarget(uri: uri))

        #expect(target.jarName == "spring-jdbc-6.2.19.jar")
        #expect(target.sourceEntry == "org/springframework/jdbc/core/JdbcTemplate.java")
    }

    @Test
    func innerClassResolvesToItsTopLevelSourceFile() throws {
        let uri = try #require(URL(string: "jdt://contents/guava-33.0.jar/com.google.common.collect/ImmutableMap%24Builder.class"))
        let target = try #require(JavaSourceJarResolver.SourceTarget(uri: uri))

        #expect(target.sourceEntry == "com/google/common/collect/ImmutableMap.java")
    }

    @Test
    func ignoresURIsWithoutAJarOrWithAnotherScheme() throws {
        // JDK classes come from the runtime image, not a sources jar.
        let jdkURI = try #require(URL(string: "jdt://contents/java.base/java/lang/String.class"))
        let fileURI = try #require(URL(string: "file:///tmp/Foo.java"))

        #expect(JavaSourceJarResolver.SourceTarget(uri: jdkURI) == nil)
        #expect(JavaSourceJarResolver.SourceTarget(uri: fileURI) == nil)
    }
}
