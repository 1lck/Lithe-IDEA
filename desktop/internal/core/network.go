package core

import "context"

// NetworkProxyIdentity is the endpoint and account a saved proxy password belongs to.
// It is stored with the settings, so editing the host or the account never sends the
// password to a different proxy.
type NetworkProxyIdentity struct {
	ProxyType string `json:"proxyType"`
	Host      string `json:"host"`
	Port      int    `json:"port"`
	Username  string `json:"username"`
}

// NetworkProxyRequest is the stored proxy settings as the host keeps them, for
// network.proxyPolicy. Mode is "system", "direct" or "custom"; ProxyType "http" or
// "socks5".
type NetworkProxyRequest struct {
	Mode             string                `json:"mode"`
	ProxyType        string                `json:"proxyType,omitempty"`
	Host             string                `json:"host"`
	Port             int                   `json:"port"`
	Username         string                `json:"username"`
	Password         string                `json:"password"`
	PasswordIdentity *NetworkProxyIdentity `json:"passwordIdentity,omitempty"`
	Exclusions       []string              `json:"exclusions"`
}

// NetworkProxyPolicy is the policy the network stack applies: Policy "system",
// "direct" or "custom". Credentials are present only for a custom policy whose
// password belongs to its endpoint. Configured is false when a custom server was
// incomplete and the policy fell back to the system's. ExclusionRules is what Core
// read the exclusions as; InvalidExclusions are the entries it could not read, which
// send no host direct.
type NetworkProxyPolicy struct {
	Policy            string                      `json:"policy"`
	ProxyType         string                      `json:"proxyType"`
	Host              string                      `json:"host"`
	Port              int                         `json:"port"`
	Username          string                      `json:"username"`
	Password          string                      `json:"password"`
	Exclusions        []string                    `json:"exclusions"`
	ExclusionRules    []NetworkProxyExclusionRule `json:"exclusionRules"`
	InvalidExclusions []string                    `json:"invalidExclusions"`
	Configured        bool                        `json:"configured"`
}

// NetworkProxyExclusionRule is one exclusion entry as Core read it. Kind is "host",
// "suffix", "ip", "cidr" or "local"; Value is the lowercase host or domain, the
// canonical address or block, or empty for "local".
type NetworkProxyExclusionRule struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

// ProxyPolicy has Core normalize stored proxy settings (network.proxyPolicy).
func (c *Client) ProxyPolicy(ctx context.Context, request NetworkProxyRequest) (NetworkProxyPolicy, error) {
	if request.Exclusions == nil {
		request.Exclusions = []string{}
	}
	var policy NetworkProxyPolicy
	err := c.Execute(ctx, "network.proxyPolicy", request, &policy)
	return policy, err
}
