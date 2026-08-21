import { describe, expect, mock, test } from "bun:test";
import {
  lombokAccessorTargetAtPosition,
  resolveLombokAccessorDefinition,
} from "./lombok-accessor-navigation";

const source = `package com.score.controller;
import com.score.entity.SysUser;
class AuthController {
  void find() { query.eq(SysUser::getUsername, "admin"); }
}`;

function dependencies(
  targetSource: string,
  files = ["src/main/java/com/score/entity/SysUser.java"],
) {
  const findSourceDefinition = mock(
    async (_source: string, declarationName: string, memberName?: string) => {
      const lines = targetSource.split(/\r?\n/);
      const expression = memberName
        ? new RegExp(`\\b${memberName}\\s*(?:=|;)`)
        : new RegExp(`\\b(?:class|interface|enum|record)\\s+${declarationName}\\b`);
      const line = lines.findIndex((value) => expression.test(value));
      if (line < 0) return null;
      const token = memberName ?? declarationName;
      return { line, utf16Column: lines[line].indexOf(token) };
    },
  );
  return {
    listWorkspaceFiles: mock(async () => files),
    readSource: mock(async () => targetSource),
    findSourceDefinition,
  };
}

describe("Lombok accessor navigation", () => {
  test("recognizes JavaBeans method references only at the accessor token", () => {
    const line = source.split("\n")[3];
    const character = line.indexOf("getUsername") + 2;
    expect(lombokAccessorTargetAtPosition(source, 3, character)).toEqual({
      declarationName: "SysUser",
      fieldName: "username",
      kind: "getter",
    });
    expect(lombokAccessorTargetAtPosition(source, 3, line.indexOf("query"))).toBeNull();
  });

  test("infers the declared type of a simple instance receiver", () => {
    const instanceSource = `class AuthController {
  SysUser currentUser;
  void authenticate(SysUser user) {
    SysUser shadowed = user;
    if (user.getStatus() == null || shadowed.getUsername() == null) {}
  }
}`;
    const lineText = instanceSource.split("\n")[4];

    expect(
      lombokAccessorTargetAtPosition(instanceSource, 4, lineText.indexOf("getStatus") + 2),
    ).toEqual({
      declarationName: "SysUser",
      fieldName: "status",
      kind: "getter",
    });
    expect(
      lombokAccessorTargetAtPosition(instanceSource, 4, lineText.indexOf("getUsername") + 2),
    ).toEqual({
      declarationName: "SysUser",
      fieldName: "username",
      kind: "getter",
    });
  });

  test("ignores same-name declarations from a closed method scope", () => {
    const instanceSource = `class AuthController {
  SysUser user;
  void unrelated(OtherUser user) {
    OtherUser local = user;
  }
  void authenticate() {
    user.getStatus();
  }
}`;
    const lineText = instanceSource.split("\n")[6];

    expect(
      lombokAccessorTargetAtPosition(instanceSource, 6, lineText.indexOf("getStatus") + 2),
    ).toEqual({
      declarationName: "SysUser",
      fieldName: "status",
      kind: "getter",
    });
    expect(
      lombokAccessorTargetAtPosition(instanceSource, 6, lineText.indexOf("user") + 2),
    ).toBeNull();
  });

  test("does not guess instance receiver types or match non-code text", () => {
    const instanceSource = `class AuthController {
  void authenticate() {
    unknown.getStatus();
    this.user.getStatus();
    user.refresh();
    // SysUser fake; fake.getStatus();
    String message = "SysUser fake; fake.getStatus()";
  }
}`;

    expect(lombokAccessorTargetAtPosition(instanceSource, 2, 17)).toBeNull();
    expect(lombokAccessorTargetAtPosition(instanceSource, 3, 19)).toBeNull();
    expect(lombokAccessorTargetAtPosition(instanceSource, 4, 10)).toBeNull();
    expect(lombokAccessorTargetAtPosition(instanceSource, 5, 30)).toBeNull();
    expect(lombokAccessorTargetAtPosition(instanceSource, 6, 42)).toBeNull();
  });

  test("preserves JavaBeans acronym field names", () => {
    expect(lombokAccessorTargetAtPosition("class A { Fn f = User::getURL; }", 0, 29)).toEqual({
      declarationName: "User",
      fieldName: "URL",
      kind: "getter",
    });
  });

  test("resolves a uniquely imported Lombok field declaration", async () => {
    const targetSource = `package com.score.entity;
import lombok.Data;
@Data
public class SysUser {
  private Long id;
  private String username;
}`;
    const deps = dependencies(targetSource, [
      "other/src/SysUser.java",
      "score-management-backend/src/main/java/com/score/entity/SysUser.java",
    ]);
    const lineText = source.split("\n")[3];

    const result = await resolveLombokAccessorDefinition(
      {
        source,
        sourceFilePath: "F:/workspace/score-management-backend/src/AuthController.java",
        workspaceRoot: "F:/workspace",
        line: 3,
        character: lineText.indexOf("getUsername") + 2,
      },
      deps,
    );

    expect(result).toEqual({
      uri: "F:/workspace/score-management-backend/src/main/java/com/score/entity/SysUser.java",
      filePath: "F:/workspace/score-management-backend/src/main/java/com/score/entity/SysUser.java",
      range: {
        start: { line: 5, character: 17 },
        end: { line: 5, character: 17 },
      },
    });
    expect(deps.findSourceDefinition).toHaveBeenCalledWith(targetSource, "SysUser", "username");
  });

  test("resolves a Lombok field from an instance accessor", async () => {
    const instanceSource = `package com.score.controller;
import com.score.entity.SysUser;
class AuthController {
  void authenticate() {
    SysUser user = findUser();
    if (user.getStatus() != 1) {}
  }
}`;
    const targetSource = `package com.score.entity;
import lombok.Data;
@Data
public class SysUser {
  private Integer status;
}`;
    const deps = dependencies(targetSource);
    const lineText = instanceSource.split("\n")[5];

    const result = await resolveLombokAccessorDefinition(
      {
        source: instanceSource,
        sourceFilePath: "F:/workspace/src/AuthController.java",
        workspaceRoot: "F:/workspace",
        line: 5,
        character: lineText.indexOf("getStatus") + 2,
      },
      deps,
    );

    expect(result).toEqual({
      uri: "F:/workspace/src/main/java/com/score/entity/SysUser.java",
      filePath: "F:/workspace/src/main/java/com/score/entity/SysUser.java",
      range: {
        start: { line: 4, character: 18 },
        end: { line: 4, character: 18 },
      },
    });
  });

  test("does not guess for non-Lombok or ambiguous target types", async () => {
    const lineText = source.split("\n")[3];
    const options = {
      source,
      sourceFilePath: "F:/workspace/src/AuthController.java",
      workspaceRoot: "F:/workspace",
      line: 3,
      character: lineText.indexOf("getUsername") + 2,
    };
    const plainJava = dependencies("public class SysUser { private String username; }");
    expect(await resolveLombokAccessorDefinition(options, plainJava)).toBeNull();
    expect(plainJava.findSourceDefinition).not.toHaveBeenCalled();

    const ambiguous = dependencies("@lombok.Data class SysUser {}", [
      "one/SysUser.java",
      "two/SysUser.java",
    ]);
    expect(await resolveLombokAccessorDefinition(options, ambiguous)).toBeNull();
    expect(ambiguous.readSource).not.toHaveBeenCalled();
  });

  test("does not apply a field annotation to a different field", async () => {
    const targetSource = `package com.score.entity;
import lombok.Getter;
public class SysUser {
  @Getter private String displayName;
  private String username;
}`;
    const deps = dependencies(targetSource);
    const lineText = source.split("\n")[3];

    const result = await resolveLombokAccessorDefinition(
      {
        source,
        sourceFilePath: "F:/workspace/src/AuthController.java",
        workspaceRoot: "F:/workspace",
        line: 3,
        character: lineText.indexOf("getUsername") + 2,
      },
      deps,
    );

    expect(result).toBeNull();
  });

  test("does not select a lone same-name type from a different package", async () => {
    const externalSource = source.replace(
      "import com.score.entity.SysUser;",
      "import vendor.model.SysUser;",
    );
    const targetSource = `package com.score.entity;
import lombok.Data;
@Data
public class SysUser {
  private String username;
}`;
    const deps = dependencies(targetSource);
    const lineText = externalSource.split("\n")[3];

    const result = await resolveLombokAccessorDefinition(
      {
        source: externalSource,
        sourceFilePath: "F:/workspace/src/AuthController.java",
        workspaceRoot: "F:/workspace",
        line: 3,
        character: lineText.indexOf("getUsername") + 2,
      },
      deps,
    );

    expect(result).toBeNull();
    expect(deps.readSource).not.toHaveBeenCalled();
  });

  test("requires a primitive boolean field for an is-accessor", async () => {
    const booleanReference = source.replace("getUsername", "isUsername");
    const targetSource = `package com.score.entity;
import lombok.Data;
@Data
public class SysUser {
  private Boolean username;
}`;
    const deps = dependencies(targetSource);
    const lineText = booleanReference.split("\n")[3];

    const result = await resolveLombokAccessorDefinition(
      {
        source: booleanReference,
        sourceFilePath: "F:/workspace/src/AuthController.java",
        workspaceRoot: "F:/workspace",
        line: 3,
        character: lineText.indexOf("isUsername") + 2,
      },
      deps,
    );

    expect(result).toBeNull();
  });
});
