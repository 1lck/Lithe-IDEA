import { openUrl } from "@tauri-apps/plugin-opener";
import { getServiceUrls } from "@/config/services";
import { UsersThreeIcon as UsersThree } from "@/ui/icons";
import { useCollaborationRuntimeStore } from "@/features/collaboration/stores/collaboration-runtime.store";
import { useAuthStore } from "@/features/window/stores/auth.store";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import Section, { SettingsView, SettingRow } from "../settings-section";

export const CollaborationSettings = () => {
  const user = useAuthStore((state) => state.user);
  const collaboration = useAuthStore((state) => state.subscription?.collaboration);
  const activeDocumentStream = useCollaborationRuntimeStore((state) => state.activeDocumentStream);
  const presenceTarget = useCollaborationRuntimeStore((state) => state.presenceTarget);
  const collaborationRuntimeActions = useCollaborationRuntimeStore((state) => state.actions);
  const { t } = useTranslation();

  const workspace = collaboration?.workspace;
  const members = collaboration?.members ?? [];
  const invitations = collaboration?.invitations ?? [];
  const channels = collaboration?.channels ?? [];
  const activeMembers = members.filter((member) => member.status === "active");
  const selectedChannel = channels.find((channel) => channel.id === presenceTarget.channelId);
  const followedMember = members.find(
    (member) => member.userId && member.userId === presenceTarget.followingUserId,
  );
  const followableMembers = members.filter(
    (member) => member.status === "active" && member.userId && member.userId !== user?.id,
  );
  const invitePolicy = collaboration?.settings?.sharedSettings.invitePolicy ?? "admins_only";
  const invitePolicyLabel =
    invitePolicy === "members"
      ? t("collaborationSettings.invitePolicyMembers")
      : invitePolicy === "admins_only"
        ? t("collaborationSettings.invitePolicyAdminsOnly")
        : invitePolicy;
  const documentStreamStatus =
    activeDocumentStream.status === "error"
      ? t("collaborationSettings.statusError")
      : activeDocumentStream.status === "live"
        ? t("collaborationSettings.statusLive")
        : activeDocumentStream.status === "connecting"
          ? t("collaborationSettings.statusConnecting")
          : activeDocumentStream.status;
  const seatLimit = String(
    collaboration?.settings?.sharedSettings.memberSeatLimit ?? t("collaborationSettings.unlimited"),
  );
  const updateLimit = String(
    collaboration?.settings?.sharedSettings.monthlyDocumentUpdateLimit ??
      t("collaborationSettings.unlimited"),
  );

  const openDashboardCollaboration = () => {
    void openUrl(getServiceUrls().dashboardCollaborationUrl);
  };

  return (
    <SettingsView>
      <Section
        title={workspace?.name ?? t("collaborationSettings.title")}
        description={t("collaborationSettings.description")}
      >
        <SettingRow
          label={t("collaborationSettings.dashboard")}
          description={t("collaborationSettings.dashboardDescription")}
        >
          <Button
            type="button"
            variant="default"
            className="ui-text-base"
            onClick={openDashboardCollaboration}
            size="sm"
          >
            <UsersThree />
            {t("collaborationSettings.open")}
          </Button>
        </SettingRow>

        <SettingRow
          label={t("collaborationSettings.members")}
          description={t("collaborationSettings.pendingInvitations", {
            count: invitations.length,
          })}
        >
          <Badge variant="default" size="compact">
            {t("collaborationSettings.activeMembers", {
              active: activeMembers.length,
              total: members.length,
            })}
          </Badge>
        </SettingRow>

        <SettingRow
          label={t("collaborationSettings.channels")}
          description={
            selectedChannel
              ? t("collaborationSettings.joinedChannel", { channel: selectedChannel.slug })
              : t("collaborationSettings.noChannelSelected")
          }
        >
          <Badge variant="default" size="compact">
            {t("collaborationSettings.channelsCount", { count: channels.length })}
          </Badge>
        </SettingRow>

        <SettingRow
          label={t("collaborationSettings.presence")}
          description={
            followedMember
              ? t("collaborationSettings.followingMember", { name: followedMember.name })
              : t("collaborationSettings.notFollowingAnyone")
          }
        >
          <div className="flex items-center gap-2">
            <Badge variant="default" size="compact">
              {t("collaborationSettings.sessionsCount", {
                count: collaboration?.presence.length ?? 0,
              })}
            </Badge>
            <Button
              type="button"
              variant="default"
              className="ui-text-base"
              disabled={!presenceTarget.channelId && !presenceTarget.followingUserId}
              onClick={() => {
                collaborationRuntimeActions.setPresenceChannel(null);
                collaborationRuntimeActions.setFollowingUser(null);
              }}
              size="sm"
            >
              {t("ui.clear")}
            </Button>
          </div>
        </SettingRow>

        <SettingRow
          label={t("collaborationSettings.documentStream")}
          description={
            activeDocumentStream.path
              ? `${activeDocumentStream.path} · v${activeDocumentStream.lastServerVersion}`
              : t("collaborationSettings.noActiveDocumentStream")
          }
        >
          <Badge
            variant={activeDocumentStream.status === "error" ? "error" : "default"}
            size="compact"
          >
            {documentStreamStatus}
          </Badge>
        </SettingRow>

        <SettingRow
          label={t("collaborationSettings.workspaceRules")}
          description={t("collaborationSettings.invitesPolicy", { policy: String(invitePolicyLabel) })}
        >
          <Badge variant="default" size="compact">
            {t("collaborationSettings.workspaceLimits", { seats: seatLimit, updates: updateLimit })}
          </Badge>
        </SettingRow>
      </Section>

      {channels.length || followableMembers.length ? (
        <Section title={t("collaborationSettings.quickPresence")}>
          {channels.slice(0, 4).map((channel) => (
            <SettingRow
              key={`channel-${channel.id}`}
              label={`#${channel.slug}`}
              description={t("collaborationSettings.channelMembersGuests", {
                members: channel.memberCount,
                guests: channel.guestCount,
              })}
            >
              <Button
                type="button"
                variant={presenceTarget.channelId === channel.id ? "accent" : "default"}
                className="ui-text-base"
                disabled={!collaboration?.capabilities.presence}
                onClick={() => collaborationRuntimeActions.setPresenceChannel(channel.id)}
                size="sm"
              >
                {t("collaborationSettings.join")}
              </Button>
            </SettingRow>
          ))}

          {followableMembers.slice(0, 4).map((member) => (
            <SettingRow
              key={`follow-${member.id}`}
              label={member.name}
              description={String(member.email ?? "")}
            >
              <Button
                type="button"
                variant={presenceTarget.followingUserId === member.userId ? "accent" : "default"}
                className="ui-text-base"
                disabled={!collaboration?.capabilities.presence}
                onClick={() => collaborationRuntimeActions.setFollowingUser(member.userId)}
                size="sm"
              >
                {t("collaborationSettings.follow")}
              </Button>
            </SettingRow>
          ))}
        </Section>
      ) : null}
    </SettingsView>
  );
};
