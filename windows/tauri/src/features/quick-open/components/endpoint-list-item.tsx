import { LinkIcon } from "@/ui/icons";
import { CommandItemBadge, CommandItemRow } from "@/ui/command";
import { getBaseName } from "@/utils/path-helpers";
import type { QuickOpenEndpointResult } from "../utils/endpoint-results";
import { SearchMatchHighlight } from "./search-match-highlight";

interface EndpointListItemProps {
  result: QuickOpenEndpointResult;
  index: number;
  isSelected: boolean;
  onClick: (result: QuickOpenEndpointResult) => void;
  onMouseEnter?: (index: number) => void;
  searchQuery: string;
}

export const EndpointListItem = ({
  result,
  index,
  isSelected,
  onClick,
  onMouseEnter,
  searchQuery,
}: EndpointListItemProps) => {
  const { endpoint, filePath, line } = result;
  const methodLabel = endpoint.httpMethods.join(", ");
  const handlerLabel = `${endpoint.controller}.${endpoint.method}`;

  return (
    <CommandItemRow
      data-item-index={index}
      onClick={() => onClick(result)}
      onMouseEnter={() => onMouseEnter?.(index)}
      isSelected={isSelected}
      icon={<LinkIcon size={14} className="text-primary" />}
      title={<SearchMatchHighlight text={endpoint.route} query={searchQuery} />}
      description={<SearchMatchHighlight text={handlerLabel} query={searchQuery} />}
      accessory={
        <>
          {methodLabel ? <CommandItemBadge>{methodLabel}</CommandItemBadge> : null}
          <CommandItemBadge>{getBaseName(filePath, filePath)}</CommandItemBadge>
          <CommandItemBadge>:{line}</CommandItemBadge>
        </>
      }
    />
  );
};
