package githubapi

import "encoding/json"

// DecodePullRequests reads the normalized list of pull requests.
func DecodePullRequests(raw json.RawMessage) ([]PullRequest, error) {
	var items []PullRequest
	err := json.Unmarshal(raw, &items)
	return items, err
}

// DecodePullRequest reads one normalized pull request.
func DecodePullRequest(raw json.RawMessage) (PullRequest, error) {
	var item PullRequest
	err := json.Unmarshal(raw, &item)
	return item, err
}

// DecodeComments reads the normalized conversation of a pull request.
func DecodeComments(raw json.RawMessage) ([]Comment, error) {
	var items []Comment
	err := json.Unmarshal(raw, &items)
	return items, err
}

// DecodeUser reads the normalized user of a currentUser answer.
func DecodeUser(raw json.RawMessage) (User, error) {
	var user User
	err := json.Unmarshal(raw, &user)
	return user, err
}

// The normalized shapes Rust Core returns (shared/contracts/github.md). They are decoded from the
// normalized JSON; the host reads them and never reshapes them.

// User is a GitHub account.
type User struct {
	Login     string  `json:"login"`
	URL       string  `json:"url"`
	AvatarURL *string `json:"avatarUrl"`
}

// Label is a GitHub label.
type Label struct {
	Name  string  `json:"name"`
	Color *string `json:"color"`
}

// PullRequest is a pull request as the list and the detail show it.
type PullRequest struct {
	Number         uint64  `json:"number"`
	Title          string  `json:"title"`
	Body           string  `json:"body"`
	State          string  `json:"state"`
	IsDraft        bool    `json:"isDraft"`
	URL            string  `json:"url"`
	Author         User    `json:"author"`
	HeadRef        string  `json:"headRef"`
	HeadRepository *string `json:"headRepository"`
	BaseRef        string  `json:"baseRef"`
	BaseRepository *string `json:"baseRepository"`
	CreatedAt      string  `json:"createdAt"`
	UpdatedAt      string  `json:"updatedAt"`
	IsMerged       bool    `json:"isMerged"`
	IsMergeable    *bool   `json:"isMergeable"`
	Additions      *uint64 `json:"additions"`
	Deletions      *uint64 `json:"deletions"`
	ChangedFiles   *uint64 `json:"changedFiles"`
	CommentsCount  uint64  `json:"commentsCount"`
	Labels         []Label `json:"labels"`
	Assignees      []User  `json:"assignees"`
}

// Comment is a conversation comment of a pull request.
type Comment struct {
	ID        uint64 `json:"id"`
	Author    User   `json:"author"`
	Body      string `json:"body"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
	URL       string `json:"url"`
}

// Branch is a branch name of the repository.
type Branch struct {
	Name string `json:"name"`
}

// Commit is a commit of a branch comparison.
type Commit struct {
	SHA     string `json:"sha"`
	Message string `json:"message"`
}

// PullRequestFile is one changed file of a pull request or comparison.
type PullRequestFile struct {
	Path      string  `json:"path"`
	Status    string  `json:"status"`
	Additions uint64  `json:"additions"`
	Deletions uint64  `json:"deletions"`
	Patch     *string `json:"patch"`
}

// Comparison is a branch comparison: its commits and changed files.
type Comparison struct {
	Commits []Commit          `json:"commits"`
	Files   []PullRequestFile `json:"files"`
}

// DeviceCode is the device authorization GitHub issued.
type DeviceCode struct {
	DeviceCode      string `json:"deviceCode"`
	UserCode        string `json:"userCode"`
	VerificationURI string `json:"verificationURI"`
	ExpiresIn       uint64 `json:"expiresIn"`
	Interval        uint64 `json:"interval"`
}

// deviceTokenResponse is one answer of the token endpoint, normalized by Core.
type deviceTokenResponse struct {
	Status      string  `json:"status"`
	AccessToken string  `json:"accessToken"`
	Error       string  `json:"error"`
	Message     *string `json:"message"`
	Interval    *uint64 `json:"interval"`
}

// DecodeBranches reads the normalized branch list of a repository.
func DecodeBranches(raw json.RawMessage) ([]Branch, error) {
	var items []Branch
	err := json.Unmarshal(raw, &items)
	return items, err
}

// DecodeComparison reads the normalized comparison of two branches.
func DecodeComparison(raw json.RawMessage) (Comparison, error) {
	var comparison Comparison
	err := json.Unmarshal(raw, &comparison)
	return comparison, err
}
