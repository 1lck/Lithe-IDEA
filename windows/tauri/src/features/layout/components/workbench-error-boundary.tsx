import { Component, type ErrorInfo, type ReactNode } from "react";
import { Button } from "@/ui/button";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyTitle } from "@/ui/empty";

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

export class WorkbenchErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error("Workbench render error:", error, errorInfo);
  }

  render() {
    if (!this.state.hasError) {
      return this.props.children;
    }

    const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);

    return (
      <Empty className="h-full min-h-0 rounded-none bg-background p-6" tone="error" role="alert">
        <EmptyHeader>
          <EmptyTitle>{t("workbench.renderErrorTitle")}</EmptyTitle>
          <EmptyDescription>
            {this.state.error?.message || t("workbench.renderErrorDescription")}
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button
            type="button"
            variant="default"
            onClick={() => this.setState({ hasError: false, error: undefined })}
          >
            {t("ui.retry")}
          </Button>
        </EmptyContent>
      </Empty>
    );
  }
}
