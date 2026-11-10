package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestSkillSearchMatchesNameDescriptionScopeAndPath(t *testing.T) {
	for _, tc := range []struct {
		query string
		want  bool
	}{
		{"", true},
		{"deploy", true},
		{"ship it", true},
		{"global", true},
		{"/home/me/.codex", true},
		{"missing", false},
	} {
		got := skillMatches("Deploy", "Ship it when tests pass", "用户", "/home/me/.codex/skills/deploy/SKILL.md", foldQuery(tc.query))
		if tc.query == "global" {
			got = skillMatches("Deploy", "ship", "Global", "/x", foldQuery(tc.query))
		}
		if got != tc.want {
			t.Errorf("query %q matched %v, want %v", tc.query, got, tc.want)
		}
	}
}

func TestSkillScopesSplitIntoGlobalAndProject(t *testing.T) {
	for scope, project := range map[string]bool{"user": false, "system": false, "admin": false, "repo": true} {
		if got := isProjectScope(scope); got != project {
			t.Errorf("scope %q project = %v", scope, got)
		}
	}
}

func TestSkillViewerReadsOnlyWhenAsked(t *testing.T) {
	b := &fakeAgentBackend{skills: core.AgentSkillListing{}}
	s, _ := newTestAgentSettings(b)
	s.readSkill(core.AgentSkill{Name: "demo", Path: "/skills/demo/SKILL.md"})
	settle(t, s, "skill read", func() bool { return !s.skills.viewing && s.skills.viewPath != "" })
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.skills.viewPath != "/skills/demo/SKILL.md" || s.skills.viewContent == "" {
		t.Fatalf("viewer = %q %q", s.skills.viewPath, s.skills.viewContent)
	}
}
