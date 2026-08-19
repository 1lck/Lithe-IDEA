import {
  BracketsCurlyIcon as Braces,
  CaretLeftIcon as ChevronLeft,
  CaretRightIcon as ChevronRight,
  CaretDoubleLeftIcon as ChevronsLeft,
  CaretDoubleRightIcon as ChevronsRight,
  DatabaseIcon as Database,
  StackIcon as Layers,
  ArrowClockwiseIcon as RefreshCw,
  TrashIcon as Trash2,
} from "@/ui/icons";
import { useEffect, useState } from "react";
import { Alert, AlertDescription } from "@/ui/alert";
import { Button } from "@/ui/button";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/ui/empty";
import Input from "@/ui/input";
import { Spinner } from "@/ui/spinner";
import Select from "@/ui/select";
import { useTranslation } from "@/i18n/locale-provider";
import { ScrollArea } from "@/ui/scroll-area";
import { cn } from "@/utils/cn";
import {
  databaseCardClassName,
  databaseChipClassName,
  databaseCodeBlockClassName,
  databaseHeaderClassName,
  databasePanelClassName,
} from "../../components/database-surface";
import { getMongoDocumentDisplayIndex } from "./mongodb-pagination";
import { createMongoDbStore } from "./stores/mongodb.store";

interface MongoDBViewerProps {
  connectionId: string;
}

export default function MongoDBViewer({ connectionId }: MongoDBViewerProps) {
  const [useStore] = useState(() => createMongoDbStore());
  const store = useStore();
  const { actions } = store;
  const [filterInput, setFilterInput] = useState("{}");
  const [sortInput, setSortInput] = useState("{}");
  const { t } = useTranslation();

  useEffect(() => {
    actions.init(connectionId);
    return () => actions.reset();
  }, [connectionId, actions]);

  useEffect(() => {
    setFilterInput(store.filterJson);
  }, [store.filterJson]);

  useEffect(() => {
    setSortInput(store.sortJson);
  }, [store.sortJson]);

  const handleApplyQuery = () => {
    actions.setQueryJson(filterInput, sortInput);
  };

  const handleResetQuery = () => {
    setFilterInput("{}");
    setSortInput("{}");
    actions.setQueryJson("{}", "{}");
  };

  return (
    <div className="flex h-full flex-col overflow-hidden bg-surface/30 text-foreground">
      <div className={databaseHeaderClassName()}>
        <div className="flex items-center gap-2">
          <div className={databaseChipClassName()}>
            <Database className="text-subtle-foreground" />
            <span className="font-sans ui-text-sm">{store.fileName}</span>
          </div>
          {store.selectedDatabase && (
            <>
              <span className="text-subtle-foreground ui-text-sm">{t("database.database")}</span>
              <Select
                value={store.selectedDatabase}
                onChange={actions.selectDatabase}
                options={store.databases.map((db) => ({ value: db, label: db }))}
                aria-label={t("database.selectDatabase")}
                size="xs"
                className="rounded-full border-border/70 bg-surface/70 px-2.5 focus:border-primary/60 focus:ring-primary/30"
              />
            </>
          )}
          <div className="ml-auto flex items-center gap-1 text-subtle-foreground ui-text-sm">
            <Layers />
            <span>{t("database.collectionsCount", { count: store.collections.length })}</span>
          </div>
        </div>
      </div>

      <div className="flex min-h-0 flex-1 gap-2 p-2 pt-1.5">
        <div className={databasePanelClassName("w-56")}>
          <div className="flex items-center gap-1.5 border-border/60 border-b px-3 py-2">
            <Layers className="text-subtle-foreground" />
            <span className="font-sans text-subtle-foreground ui-text-sm">
              {t("database.collections")}
            </span>
          </div>
          <ScrollArea className="flex-1" contentClassName="space-y-0.5 p-1.5">
            {store.collections.map((col) => (
              <Button
                key={col.name}
                onClick={() => actions.selectCollection(col.name)}
                variant="ghost"
                size="xs"
                className={cn(
                  "block h-auto w-full justify-start rounded-lg px-2 py-1 text-left ui-text-sm leading-row",
                  store.selectedCollection === col.name && "bg-selected",
                )}
                aria-label={t("database.selectCollection", { collection: col.name })}
              >
                {col.name}
              </Button>
            ))}
          </ScrollArea>
        </div>

        <div className={databasePanelClassName("flex-1")}>
          <div className="flex items-center gap-2 border-border/60 border-b px-3 py-2">
            <Input
              className="flex-1"
              placeholder='Filter JSON, e.g. {"name": "John"}'
              value={filterInput}
              onChange={(e) => setFilterInput(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleApplyQuery()}
              aria-label={t("database.mongodbFilterQuery")}
            />
            <Input
              className="w-56"
              placeholder='Sort JSON, e.g. {"createdAt": -1}'
              value={sortInput}
              onChange={(e) => setSortInput(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handleApplyQuery()}
              aria-label={t("database.mongodbSortQuery")}
            />
            <Button
              onClick={handleApplyQuery}
              className="gap-1.5"
              aria-label={t("database.applyQuery")}
              size="xs"
            >
              <Braces />
              {t("database.apply")}
            </Button>
            <Button
              onClick={handleResetQuery}
              variant="ghost"
              size="xs"
              className="px-2 py-1 text-subtle-foreground"
              aria-label={t("database.resetQuery")}
            >
              {t("database.reset")}
            </Button>
            <Button
              onClick={() => actions.refresh()}
              variant="ghost"
              size="icon-xs"
              className="text-subtle-foreground"
              aria-label={t("database.refresh")}
            >
              <RefreshCw />
            </Button>
          </div>

          {!store.isLoading && !store.selectedCollection && (
            <Empty>
              <EmptyHeader>
                <EmptyTitle>{t("database.selectCollectionTitle")}</EmptyTitle>
                <EmptyDescription>
                  {t("database.selectCollectionDescription")}
                </EmptyDescription>
              </EmptyHeader>
            </Empty>
          )}

          {store.error && (
            <Alert tone="error" className="mx-3 mt-3 mb-2 w-auto">
              <AlertDescription>{store.error}</AlertDescription>
            </Alert>
          )}

          {store.isLoading && (
            <Empty>
              <EmptyDescription>
                <Spinner label={t("ui.loading")} showLabel />
              </EmptyDescription>
            </Empty>
          )}

          {!store.isLoading && store.documents.length > 0 && (
            <div className="custom-scrollbar flex-1 overflow-auto p-3">
              <div className="mb-3 flex items-center justify-between">
                <div className="text-subtle-foreground ui-text-sm">
                  {t("database.documentsCount", { count: store.totalCount })}
                </div>
                {store.selectedCollection && (
                  <div className={databaseChipClassName("text-subtle-foreground ui-text-sm")}>
                    {store.selectedCollection}
                  </div>
                )}
              </div>
              <div className="space-y-2">
                {store.documents.map((doc, i) => {
                  const id = doc._id ? String(doc._id) : String(i);
                  const displayIndex = getMongoDocumentDisplayIndex(
                    store.currentPage,
                    store.pageSize,
                    i,
                  );
                  return (
                    <div
                      key={id}
                      className={databaseCardClassName(
                        "group p-3 shadow-[0_10px_30px_-28px_rgba(0,0,0,0.55)]",
                      )}
                    >
                      <div className="mb-2 flex items-center justify-between gap-2">
                        <div className="truncate text-subtle-foreground ui-text-sm">
                          {t("database.documentNumber", { number: displayIndex })}
                        </div>
                        <Button
                          onClick={() => actions.deleteDocument(id)}
                          variant="ghost"
                          size="icon-xs"
                          className="text-destructive opacity-0 transition-[opacity,background-color] duration-(--app-duration-fast) ease-(--app-ease-smooth) hover:bg-destructive/10 group-hover:opacity-100"
                          aria-label={t("database.deleteDocument", { id })}
                        >
                          <Trash2 />
                        </Button>
                      </div>
                      <pre
                        className={databaseCodeBlockClassName("overflow-x-auto bg-background/70")}
                      >
                        {JSON.stringify(doc, null, 2)}
                      </pre>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {!store.isLoading && store.documents.length === 0 && store.selectedCollection && (
            <Empty>
              <EmptyHeader>
                <EmptyTitle>{t("database.noDocumentsFound")}</EmptyTitle>
                <EmptyDescription>
                  {t("database.emptyFilterResult")}
                </EmptyDescription>
              </EmptyHeader>
            </Empty>
          )}

          {!store.isLoading && store.totalPages > 1 && (
            <div className="flex items-center justify-between border-border/60 border-t px-3 py-2">
              <div className="flex items-center gap-2">
                <Select
                  value={store.pageSize.toString()}
                  options={[
                    { value: "10", label: "10" },
                    { value: "25", label: "25" },
                    { value: "50", label: "50" },
                    { value: "100", label: "100" },
                    { value: "500", label: "500" },
                  ]}
                  onChange={(value) => actions.setPageSize(Number(value))}
                  aria-label={t("database.documentsPerPage")}
                  size="xs"
                  className="min-w-16"
                />
                <span className="font-sans text-subtle-foreground ui-text-sm">
                  {t("database.perPage")}
                </span>
              </div>
              <div className="flex items-center gap-1">
                <span className="mr-2 font-sans text-subtle-foreground ui-text-sm">
                  {t("database.pageOf", { page: store.currentPage, pages: store.totalPages })}
                </span>
                <Button
                  onClick={() => actions.setCurrentPage(1)}
                  disabled={store.currentPage === 1}
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("database.firstPage")}
                >
                  <ChevronsLeft />
                </Button>
                <Button
                  onClick={() => actions.setCurrentPage(store.currentPage - 1)}
                  disabled={store.currentPage === 1}
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("ui.previousPage")}
                >
                  <ChevronLeft />
                </Button>
                <Button
                  onClick={() => actions.setCurrentPage(store.currentPage + 1)}
                  disabled={store.currentPage === store.totalPages}
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("ui.nextPage")}
                >
                  <ChevronRight />
                </Button>
                <Button
                  onClick={() => actions.setCurrentPage(store.totalPages)}
                  disabled={store.currentPage === store.totalPages}
                  variant="ghost"
                  size="icon-xs"
                  aria-label={t("database.lastPage")}
                >
                  <ChevronsRight />
                </Button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
