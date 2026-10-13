import { NumberField as NumberFieldPrimitive } from "@base-ui/react/number-field";
import { cva } from "class-variance-authority";
import type React from "react";
import { CaretDownIcon, CaretUpIcon } from "@/ui/icons";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { controlSizeVariants, controlSurfaceVariants } from "@/utils/control-variants";
import { cn } from "@/utils/cn";

interface InputProps extends Omit<
  React.InputHTMLAttributes<HTMLInputElement>,
  "defaultValue" | "max" | "min" | "onChange" | "size" | "step" | "value"
> {
  size?: "xs" | "sm" | "md";
  value?: number | string;
  defaultValue?: number | string;
  min?: number | string;
  max?: number | string;
  step?: number | string;
  onChange?: (value: number) => void;
}

const numberInputFieldPadding = {
  xs: "px-2",
  sm: "px-2",
  md: "px-3",
} as const;

const numberInputTextSize = {
  xs: "ui-text-sm",
  sm: "ui-text-sm",
  md: "ui-text-base",
} as const;

const numberInputButtonSize = { xs: "icon-xs", sm: "icon-sm", md: "icon" } as const;
const numberInputIconSize = { xs: "size-3", sm: "size-3.5", md: "size-4" } as const;

const numberInputGroupVariants = cva("flex min-w-0 items-center gap-2", {
  variants: {
    disabled: {
      true: "opacity-50",
      false: "",
    },
  },
});

function toNumber(value: number | string | undefined) {
  if (value === undefined || value === "") return undefined;
  const parsed = typeof value === "number" ? value : Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export default function NumberInput({
  size = "sm",
  value,
  defaultValue,
  onChange,
  className,
  disabled = false,
  min,
  max,
  step,
  required,
  readOnly,
  name,
  id,
  ...props
}: InputProps) {
  const { t } = useTranslation();
  const numericStep = toNumber(step) ?? 1;
  const precision =
    numericStep > 0 ? (numericStep.toString().split(".")[1]?.length ?? 0) : undefined;

  return (
    <NumberFieldPrimitive.Root
      id={id}
      name={name}
      value={toNumber(value)}
      defaultValue={toNumber(defaultValue) ?? 0}
      min={toNumber(min)}
      max={toNumber(max)}
      step={numericStep}
      required={required}
      readOnly={readOnly}
      disabled={disabled}
      format={{
        useGrouping: false,
        maximumFractionDigits: precision,
      }}
      onValueChange={(nextValue) => {
        if (nextValue !== null) onChange?.(nextValue);
      }}
      className={cn(numberInputGroupVariants({ disabled }), className)}
    >
      <NumberFieldPrimitive.Input
        data-setting-primary-control="true"
        {...props}
        className={cn(
          controlSurfaceVariants({ variant: "default" }),
          controlSizeVariants({ size }),
          numberInputTextSize[size],
          numberInputFieldPadding[size],
          "w-0 min-w-[5ch] flex-1 appearance-none text-center tabular-nums leading-normal text-foreground outline-none placeholder:text-subtle-foreground [&::-webkit-inner-spin-button]:m-0 [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:m-0 [&::-webkit-outer-spin-button]:appearance-none",
        )}
      />

      <div className="flex shrink-0 items-center gap-1">
        <NumberFieldPrimitive.Increment
          render={<Button type="button" variant="default" size={numberInputButtonSize[size]} />}
          aria-label={t("ui.increaseValue")}
        >
          <CaretUpIcon className={numberInputIconSize[size]} />
        </NumberFieldPrimitive.Increment>
        <NumberFieldPrimitive.Decrement
          render={<Button type="button" variant="default" size={numberInputButtonSize[size]} />}
          aria-label={t("ui.decreaseValue")}
        >
          <CaretDownIcon className={numberInputIconSize[size]} />
        </NumberFieldPrimitive.Decrement>
      </div>
    </NumberFieldPrimitive.Root>
  );
}
