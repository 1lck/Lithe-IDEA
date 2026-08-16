//! Shared community integrations and their cross-platform protocol boundaries.

mod discourse;

pub(crate) use discourse::{
    begin_authorization, categories, complete_authorization, revoke, search, topic, topics,
    DiscourseAuthorizationBeginRequest, DiscourseAuthorizationCompleteRequest,
    DiscourseCategoriesRequest, DiscourseRevokeRequest, DiscourseSearchRequest,
    DiscourseTopicRequest, DiscourseTopicsRequest,
};
