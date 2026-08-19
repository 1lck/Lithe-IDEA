import { EyeIcon as Eye, EyeSlashIcon as EyeOff } from "@/ui/icons";
import { useEffect, useState } from "react";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Field, FieldError, FieldLabel } from "@/ui/field";
import { useTranslation } from "@/i18n/locale-provider";
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from "@/ui/input-group";
import type { RemoteConnection } from "../types/remote.types";

interface PasswordPromptDialogProps {
  isOpen: boolean;
  connection: RemoteConnection | null;
  onClose: () => void;
  onConnect: (connectionId: string, password: string) => Promise<void>;
}

const PasswordPromptDialog = ({
  isOpen,
  connection,
  onClose,
  onConnect,
}: PasswordPromptDialogProps) => {
  const { t } = useTranslation();
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  useEffect(() => {
    if (isOpen) {
      setPassword("");
      setShowPassword(false);
      setIsConnecting(false);
      setErrorMessage("");
    }
  }, [isOpen]);

  if (!isOpen || !connection) return null;

  const handleConnect = async () => {
    if (!password.trim()) {
      setErrorMessage(t("remote.passwordRequired"));
      return;
    }

    setIsConnecting(true);
    setErrorMessage("");

    try {
      await onConnect(connection.id, password);
      onClose();
    } catch (error) {
      const rawError = error instanceof Error ? error.message : String(error);
      let friendlyError = rawError;

      if (rawError.includes("Authentication failed") || rawError.includes("username/password")) {
        friendlyError = t("remote.incorrectUsernameOrPassword");
      } else if (rawError.includes("Connection refused") || rawError.includes("unreachable")) {
        friendlyError = t("remote.cannotConnectToServer");
      } else if (rawError.includes("timeout")) {
        friendlyError = t("remote.connectionTimedOut");
      } else if (rawError.includes("Host key verification failed")) {
        friendlyError = t("remote.hostKeyVerificationFailed");
      } else if (rawError.includes("Permission denied")) {
        friendlyError = t("remote.permissionDenied");
      } else if (rawError.includes("No route to host")) {
        friendlyError = t("remote.noRouteToHost");
      }

      setErrorMessage(friendlyError || t("remote.connectionFailed"));
    } finally {
      setIsConnecting(false);
    }
  };

  return (
    <Dialog
      onClose={onClose}
      title={t("remote.enterPassword")}
      size="sm"
      footer={
        <>
          <Button onClick={onClose} variant="ghost" size="xs">
            {t("ui.cancel")}
          </Button>
          <Button onClick={handleConnect} disabled={!password.trim() || isConnecting} size="xs">
            {isConnecting ? t("projectPicker.connecting") : t("database.connect")}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="ui-text-sm text-subtle-foreground">
          {t("remote.enterPasswordForPrefix")}{" "}
          <span className="font-medium text-foreground">{connection.name}</span>{" "}
          {t("remote.enterPasswordForSuffix", {
            user: connection.username,
            host: connection.host,
            port: connection.port,
          })}
        </p>

        <Field data-invalid={Boolean(errorMessage)}>
          <FieldLabel htmlFor="password-prompt">{t("database.password")}</FieldLabel>
          <InputGroup>
            <InputGroupInput
              id="password-prompt"
              type={showPassword ? "text" : "password"}
              value={password}
              onChange={(e) => {
                setPassword(e.target.value);
                setErrorMessage("");
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter" && password.trim() && !isConnecting) {
                  event.preventDefault();
                  void handleConnect();
                }
              }}
              placeholder={t("remote.enterPassword")}
              autoFocus
              disabled={isConnecting}
            />
            <InputGroupAddon align="inline-end">
              <InputGroupButton
                type="button"
                variant="ghost"
                onClick={() => setShowPassword(!showPassword)}
                tooltip={showPassword ? t("remote.hidePassword") : t("remote.showPassword")}
                size="icon-sm"
              >
                {showPassword ? <EyeOff /> : <Eye />}
              </InputGroupButton>
            </InputGroupAddon>
          </InputGroup>
          <FieldError>{errorMessage}</FieldError>
        </Field>
      </div>
    </Dialog>
  );
};

export default PasswordPromptDialog;
