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

// DecodeCheckRuns reads the normalized check runs or commit statuses of a commit: the checks of a
// pull request's head read through either operation, decoded the same way.
func DecodeCheckRuns(raw json.RawMessage) ([]CheckRun, error) {
	var items []CheckRun
	err := json.Unmarshal(raw, &items)
	return items, err
}

// DecodeReviewComments reads the normalized line review comments of a pull request.
func DecodeReviewComments(raw json.RawMessage) ([]ReviewComment, error) {
	var items []ReviewComment
	err := json.Unmarshal(raw, &items)
	return items, err
}

// DecodeUser reads the normalized user of a currentUser answer.
func DecodeUser(raw json.RawMessage) (User, error) {
	var user User
	err := json.Unmarshal(raw, &user)
	return user, err
}

// The normalized shapes Rust Core returns (Lithe-core-rust rust/contracts/github.md). They are decoded from the
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
	// HeadSHA is the head commit's SHA, which the checks of the pull request are read for. The
	// normalized shape carries it as headSha; without it the checks cannot be read.
	HeadSHA *string `json:"headSha"`
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

// CheckRun is one check of a commit: a check run, or a commit status. Status is the state the check
// is in ("queued", "in_progress" or "completed"; a legacy pending status reads "in_progress").
// Conclusion is set once it completed. DetailsURL leads to the check's page.
type CheckRun struct {
	Name       string  `json:"name"`
	Status     string  `json:"status"`
	Conclusion *string `json:"conclusion"`
	DetailsURL *string `json:"detailsUrl"`
}

// ReviewComment is one line comment of a pull request's review. Line is nil when the comment's
// anchor is outdated: the code it was made on has changed since. InReplyTo is nil for the root
// comment of a thread and the root's ID for a reply.
type ReviewComment struct {
	ID        uint64  `json:"id"`
	Path      string  `json:"path"`
	Line      *uint64 `json:"line"`
	Side      string  `json:"side"`
	Body      string  `json:"body"`
	Author    User    `json:"author"`
	InReplyTo *uint64 `json:"inReplyTo"`
	CreatedAt string  `json:"createdAt"`
	URL       string  `json:"url"`
}
