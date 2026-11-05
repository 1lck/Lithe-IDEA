import { CaretRightIcon as CaretRight } from "@/ui/icons";
import { useEffect, useState } from "react";
import { Spinner } from "@/ui/spinner";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import {
  requestFirstVariablePage,
  requestNextVariablePage,
} from "../services/debug-variable-paging";
import type { DebugRequestContext, DebugScope, DebugVariable } from "../types/debugger.types";
import type { VariablePageCursor } from "../api/variable-paging-api";
import { DebugEmptyState } from "./debugger-panels";

interface DebugVariablesPanelProps {
  activeSessionId?: string;
  selectedFrameId: number | null;
  scopes: DebugScope[];
  variablesByReference: Record<number, DebugVariable[]>;
  variablePageCursors: Record<number, VariablePageCursor>;
  pendingRequests: Record<string, DebugRequestContext>;
}

export function DebugVariablesPanel({
  activeSessionId,
  selectedFrameId,
  scopes,
  variablesByReference,
  variablePageCursors,
  pendingRequests,
}: DebugVariablesPanelProps) {
  const [expandedVariableReferences, setExpandedVariableReferences] = useState<Set<number>>(
    () => new Set(),
  );
  const { t } = useTranslation();

  useEffect(() => {
    setExpandedVariableReferences(new Set());
  }, [activeSessionId, selectedFrameId]);

  const isVariableReferencePending = (variablesReference: number) =>
    Object.values(pendingRequests).some(
      (request) =>
        request.command === "variables" && request.variablesReference === variablesReference,
    );

  const toggleVariableExpansion = async (container: DebugVariable) => {
    const { variablesReference } = container;
    if (!activeSessionId || variablesReference <= 0) return;

    const shouldLoadChildren =
      !expandedVariableReferences.has(variablesReference) &&
      !variablesByReference[variablesReference];

    setExpandedVariableReferences((current) => {
      const next = new Set(current);
      if (next.has(variablesReference)) next.delete(variablesReference);
      else next.add(variablesReference);
      return next;
    });

    if (!shouldLoadChildren) return;

    try {
      await requestFirstVariablePage(activeSessionId, container);
    } catch {
      setExpandedVariableReferences((current) => {
        const next = new Set(current);
        next.delete(variablesReference);
        return next;
      });
    }
  };

  const renderLoadMore = (variablesReference: number, depth: number) =>
    activeSessionId && variablePageCursors[variablesReference]?.next ? (
      <button
        type="button"
        className="py-1 text-left ui-text-sm text-subtle-foreground hover:text-foreground"
        style={{ paddingLeft: 18 + depth * 12 }}
        disabled={isVariableReferencePending(variablesReference)}
        onClick={() => void requestNextVariablePage(activeSessionId, variablesReference)}
      >
        {t("debugger.loadMoreVariables")}
      </button>
    ) : null;

  const renderVariables = (variables: DebugVariable[], parentReference: number, depth = 0) =>
    variables.map((variable, index) => {
      const canExpand = variable.variablesReference > 0;
      const isExpanded = expandedVariableReferences.has(variable.variablesReference);
      const childVariables = variablesByReference[variable.variablesReference] ?? [];
      const isLoading = isVariableReferencePending(variable.variablesReference);

      return (
        <div key={`${parentReference}-${variable.name}-${index}`}>
          <div
            className="grid grid-cols-[minmax(0,0.42fr)_minmax(0,0.58fr)] gap-2 py-1 pr-3 ui-text-sm"
            style={{ paddingLeft: 18 + depth * 12 }}
          >
            <button
              type="button"
              className={cn(
                "flex min-w-0 items-center gap-1 text-left text-subtle-foreground",
                canExpand && "hover:text-foreground",
              )}
              disabled={!canExpand}
              onClick={() => void toggleVariableExpansion(variable)}
            >
              <CaretRight
                size={10}
                className={cn(
                  "shrink-0 transition-transform",
                  isExpanded && "rotate-90",
                  !canExpand && "opacity-0",
                )}
              />
              <span className="truncate">{variable.name}</span>
            </button>
            <span className="truncate font-mono text-foreground">
              {isLoading ? (
                <Spinner label={t("debugger.loadingVariable")} compact />
              ) : (
                variable.value || variable.type || ""
              )}
            </span>
          </div>
          {isExpanded && childVariables.length > 0
            ? renderVariables(childVariables, variable.variablesReference, depth + 1)
            : null}
          {isExpanded ? renderLoadMore(variable.variablesReference, depth + 1) : null}
        </div>
      );
    });

  if (scopes.length === 0) {
    return <DebugEmptyState>{t("debugger.variablesEmpty")}</DebugEmptyState>;
  }

  return (
    <div className="py-1">
      {scopes.map((scope) => {
        const variables = variablesByReference[scope.variablesReference] ?? [];
        return (
          <div key={`${scope.name}-${scope.variablesReference}`}>
            <div className="flex items-center justify-between px-3 py-1.5 ui-text-sm">
              <span className="font-medium text-foreground">{scope.name}</span>
              <span className="ui-text-sm text-subtle-foreground">{variables.length}</span>
            </div>
            {scope.expensive && variables.length === 0 && activeSessionId ? (
              <button
                type="button"
                className="px-6 pb-1.5 text-left ui-text-sm text-subtle-foreground hover:text-foreground"
                disabled={isVariableReferencePending(scope.variablesReference)}
                onClick={() => void requestFirstVariablePage(activeSessionId, scope)}
              >
                {t("debugger.loadScopeVariables")}
              </button>
            ) : variables.length === 0 ? (
              <div className="px-6 pb-1.5 ui-text-sm text-subtle-foreground">
                {t("debugger.empty")}
              </div>
            ) : (
              renderVariables(variables, scope.variablesReference)
            )}
            {renderLoadMore(scope.variablesReference, 0)}
          </div>
        );
      })}
    </div>
  );
}
