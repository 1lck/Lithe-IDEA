// A deterministic Java project for the performance scenarios. Sizes are part of
// the measurement: changing them invalidates comparisons with older baselines.

export const PROJECT_ROOT = "C:/perf/acme-orders";
export const SMALL_FILE = "src/main/java/com/acme/orders/OrderService.java";
export const LARGE_FILE = "src/main/java/com/acme/orders/generated/Repositories.java";
export const SERVICE_DIRECTORY = "src/main/java/com/acme/orders/service";
export const SERVICE_COUNT = 1_000;
// Sorted before the large service folder, so its rows stay inside the virtualized tree.
export const MODEL_DIRECTORY = "src/main/java/com/acme/orders/model";
export const MODEL_COUNT = 4;
export const LARGE_FILE_LINES = 20_000;

const repositoryClass = (index) => `/** Repository for entity ${index}. */
class Repository${index}<T extends Comparable<T>> {
  private final java.util.Map<Long, T> items = new java.util.HashMap<>();
  private final String name = "repo-${index}";

  public java.util.Optional<T> find(long id) {
    return java.util.Optional.ofNullable(items.get(id > ${index} ? id : ${index}L));
  }

  public void save(long id, T item) {
    if (id < 0) throw new IllegalArgumentException("invalid id " + id + " in " + name);
    items.put(id, item);
  }
}
`;

function javaSource(packageName, lines) {
  const out = [`package ${packageName};`, "", "import java.util.Objects;", ""];
  let count = out.length;
  for (let index = 0; count < lines; index += 1) {
    const block = repositoryClass(index);
    out.push(block);
    count += block.split("\n").length;
  }
  return `${out.join("\n")}\n`;
}

const modelSource = (index) => `package com.acme.orders.model;

public record Model${index}(long id, String name) {}
`;

const serviceSource = (index) => `package com.acme.orders.service;

/** Generated service ${index}. */
public class Service${index} {
  public int handle(int value) {
    return value + ${index};
  }
}
`;

export function createFixture() {
  const files = {
    "pom.xml": `<project>\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>com.acme</groupId>\n  <artifactId>orders</artifactId>\n  <version>1.0.0</version>\n</project>\n`,
    "README.md": "# Orders\n",
    [SMALL_FILE]: javaSource("com.acme.orders", 200),
    [LARGE_FILE]: javaSource("com.acme.orders.generated", LARGE_FILE_LINES),
  };
  for (let index = 0; index < MODEL_COUNT; index += 1) {
    files[`${MODEL_DIRECTORY}/Model${index}.java`] = modelSource(index);
  }
  for (let index = 0; index < SERVICE_COUNT; index += 1) {
    files[`${SERVICE_DIRECTORY}/Service${index}.java`] = serviceSource(index);
  }
  return { root: PROJECT_ROOT, files };
}
