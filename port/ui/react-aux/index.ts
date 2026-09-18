// calfNXT macOS — React glue over AUX widgets + AWML.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// componentFromWidget, useDynamicValueReadonly and the useWidgets* family over
// AWML Bindings/DynamicValue.
import {
  createRef,
  Component,
  createElement,
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
} from 'react';
import { DynamicValue } from '@deutschesoft/awml';
// Bindings is not re-exported from the package root; deep-import via the
// package's "./src/*" exports mapping.
import { Bindings } from '@deutschesoft/awml/src/bindings.js';

// ---------------------------------------------------------------------------
// helpers

function hasOwnProperty(o: object, name: string): boolean {
  return Object.prototype.hasOwnProperty.call(o, name);
}

function forEachChangedProperty(
  a: Record<string, unknown> | undefined,
  b: Record<string, unknown> | undefined,
  removeCb: (name: string, prevValue: unknown) => void,
  addCb: (name: string, value: unknown, prevValue: unknown) => void,
): void {
  if (a === b) return;
  if (a)
    for (const name in a) {
      if (b && hasOwnProperty(b, name)) continue;
      removeCb(name, a[name]);
    }
  if (b)
    for (const name in b) {
      const value = b[name];
      const prevValue = a ? a[name] : void 0;
      if (prevValue === value) continue;
      addCb(name, value, prevValue);
    }
}

// ---------------------------------------------------------------------------
// useDynamicValueReadonly

export function useDynamicValueReadonly<T>(
  dynamicValue: DynamicValue<T> | undefined | null,
  defaultValue: T,
  replay?: boolean,
): T;
export function useDynamicValueReadonly<T>(
  dynamicValue: DynamicValue<T> | undefined | null,
): T | undefined;
export function useDynamicValueReadonly<T>(
  dynamicValue: DynamicValue<T> | undefined | null,
  defaultValue: T | undefined = undefined,
  replay = true,
): T | undefined {
  const hasDynamicValue = !!dynamicValue;
  const [value, setValue] = useState<T | undefined>(
    replay && dynamicValue && dynamicValue.hasValue
      ? dynamicValue.value
      : defaultValue,
  );

  useEffect(() => {
    if (hasDynamicValue && dynamicValue) {
      return dynamicValue.subscribe(setValue, replay) as () => void;
    }
    setValue(defaultValue);
    return undefined;
  }, [hasDynamicValue, dynamicValue, replay]);

  return hasDynamicValue ? value : defaultValue;
}

// ---------------------------------------------------------------------------
// componentFromWidget

interface WidgetInstance {
  setParent(p: unknown): void;
  enableDraw(): void;
  set(name: string, value: unknown): void;
  reset(name: string): void;
  subscribe(event: string, cb: (...args: unknown[]) => void): () => void;
  destroy(): void;
}
interface WidgetCtor<T extends WidgetInstance> {
  new (options: Record<string, unknown>): T;
  getOptionTypes(): Record<string, unknown>;
}

interface BindingDesc {
  name?: string;
  backendValue?: DynamicValue<unknown>;
  pipe?: (dv: DynamicValue<unknown>) => DynamicValue<unknown>;
  transformReceive?: (v: unknown) => unknown;
  transformSend?: (v: unknown) => unknown;
  replayReceive?: boolean;
  replaySend?: boolean;
  sync?: boolean;
  debug?: boolean;
}
type BindingDefaults = Record<string, BindingDesc | BindingDesc[]>;

function createBindingDescription(
  defaultDescription: BindingDesc,
  value: unknown,
): BindingDesc | null {
  if (value instanceof DynamicValue) {
    return { ...defaultDescription, backendValue: value };
  }
  if (typeof value === 'object' && value !== null) {
    return { ...defaultDescription, ...(value as BindingDesc) };
  }
  if (value === undefined || value === null) return null;
  throw new TypeError(
    'Unexpected value for binding description. Expected DynamicValue or BindingDescription.',
  );
}

function initializeEventSubscriptions(
  auxWidget: WidgetInstance,
  eventSubscriptions: Map<string, () => void>,
  props: Record<string, unknown>,
): void {
  for (const name in props) {
    if (!name.startsWith('on')) continue;
    const value = props[name];
    const eventName = name.slice(2).toLowerCase();
    if (typeof value === 'function') {
      eventSubscriptions.set(
        eventName,
        auxWidget.subscribe(eventName, value as (...a: unknown[]) => void),
      );
    } else {
      throw new TypeError('Expected function as event handler.');
    }
  }
}

const classListSplit = /[ \t\n\r\f]+/;

function updateClassName(
  element: HTMLElement,
  className: string,
  prevClassName: string,
  defaultClassNames: string[],
): void {
  const classNames = className.split(classListSplit);
  const prevClassNames = prevClassName.split(classListSplit);
  classNames.forEach((name) => {
    if (name === '' || prevClassNames.includes(name) || defaultClassNames.includes(name))
      return;
    element.classList.add(name);
  });
  prevClassNames.forEach((name) => {
    if (name === '' || classNames.includes(name) || defaultClassNames.includes(name))
      return;
    element.classList.remove(name);
  });
}

function updateRef(ref: unknown, value: unknown): void {
  if (typeof ref === 'function') (ref as (v: unknown) => void)(value);
  else if (typeof ref === 'object' && ref !== null && 'current' in ref)
    (ref as { current: unknown }).current = value;
  else if (ref != null) throw TypeError('Expected react Ref or callback.');
}

export function componentFromWidget<T extends WidgetInstance>(
  Widget: WidgetCtor<T>,
  bindingDefaults?: BindingDefaults,
  defaultOptions?: Record<string, unknown>,
  defaultClassName?: string,
) {
  const bindings = bindingDefaults || {};
  const defaults = defaultOptions || {};
  const defaultClassNames = defaultClassName
    ? defaultClassName.split(classListSplit).filter((s) => s.length)
    : [];
  const optionTypes = Widget.getOptionTypes();

  const propertyToBindingIndex = new Map<string, number>(
    Object.keys(bindings).map((name, i) => [name, i]),
  );
  const indexToBindingDefault = Object.values(bindings);
  const indexToBindingPropertyName = Object.keys(bindings);

  function optionsFromProps(props: Record<string, unknown>): Record<string, unknown> {
    const result: Record<string, unknown> = Object.assign({}, defaults);
    for (const key in props) if (optionTypes[key]) result[key] = props[key];
    return result;
  }

  function initializeBindingDescriptions(
    bindingDescriptions: (BindingDesc | BindingDesc[] | null)[],
    props: Record<string, unknown>,
  ): boolean {
    let changed = false;
    for (let i = 0; i < bindingDescriptions.length; i++) {
      const propertyName = indexToBindingPropertyName[i];
      if (!hasOwnProperty(props, propertyName)) continue;
      const value = props[propertyName];
      const def = indexToBindingDefault[i];
      bindingDescriptions[i] = Array.isArray(def)
        ? def.map((d) => createBindingDescription(d, value)).filter(Boolean) as BindingDesc[]
        : createBindingDescription(def, value);
      changed = true;
    }
    return changed;
  }

  return class extends Component<Record<string, unknown> & { style?: CSSProperties; widgetRef?: unknown }> {
    private elementRef: RefObject<HTMLDivElement> = createRef();
    private auxWidget: T | null = null;
    private bindings: Bindings | null = null;
    private bindingDescriptions: (BindingDesc | BindingDesc[] | null)[] =
      new Array(indexToBindingDefault.length).fill(null);
    private eventSubscriptions = new Map<string, () => void>();

    private _updateBindings(): void {
      const { bindings: b, bindingDescriptions } = this;
      b?.update(
        bindingDescriptions.flat().filter((d): d is BindingDesc => !!d) as never,
      );
    }

    componentDidMount(): void {
      const element = this.elementRef.current!;
      const props = this.props;
      const auxWidget = new Widget({ element, ...optionsFromProps(props) });
      const bindings = new Bindings(auxWidget as never);
      auxWidget.setParent(null);
      auxWidget.enableDraw();
      this.auxWidget = auxWidget;
      this.bindings = bindings;
      if (initializeBindingDescriptions(this.bindingDescriptions, props))
        this._updateBindings();
      initializeEventSubscriptions(auxWidget, this.eventSubscriptions, props);
      defaultClassNames.forEach((name) => element.classList.add(name));
      if (hasOwnProperty(props, 'className'))
        updateClassName(element, props.className as string, '', defaultClassNames);
      if (props.widgetRef) updateRef(props.widgetRef, auxWidget);
    }

    componentDidUpdate(prevProps: Record<string, unknown>): void {
      const { auxWidget, props, bindingDescriptions, eventSubscriptions } = this;
      if (!auxWidget) return;
      let bindingsChanged = false;

      forEachChangedProperty(
        prevProps,
        props,
        (name, prevValue) => {
          if (name.endsWith('$')) {
            const i = propertyToBindingIndex.get(name);
            if (i === void 0) return;
            bindingDescriptions[i] = null;
            bindingsChanged = true;
          } else if (name.startsWith('on')) {
            const eventName = name.slice(2).toLowerCase();
            const un = eventSubscriptions.get(eventName);
            eventSubscriptions.delete(eventName);
            if (un) un();
          } else if (hasOwnProperty(optionTypes, name)) {
            if (hasOwnProperty(defaults, name)) auxWidget.set(name, defaults[name]);
            else auxWidget.reset(name);
          } else if (name === 'className') {
            updateClassName(this.elementRef.current!, '', prevValue as string, defaultClassNames);
          }
        },
        (name, value, prevValue) => {
          if (name.endsWith('$')) {
            const i = propertyToBindingIndex.get(name);
            if (i === void 0) {
              console.warn('Unknown binding %o=%o.', name, value);
              return;
            }
            const def = indexToBindingDefault[i];
            bindingDescriptions[i] = Array.isArray(def)
              ? def.map((d) => createBindingDescription(d, value)).filter(Boolean) as BindingDesc[]
              : createBindingDescription(def, value);
            bindingsChanged = true;
          } else if (name.startsWith('on')) {
            const eventName = name.slice(2).toLowerCase();
            const un = eventSubscriptions.get(eventName);
            if (un) un();
            if (typeof value === 'function') {
              eventSubscriptions.set(
                eventName,
                auxWidget.subscribe(eventName, value as (...a: unknown[]) => void),
              );
            } else {
              eventSubscriptions.delete(eventName);
              throw new TypeError('Expected function as event handler.');
            }
          } else if (hasOwnProperty(optionTypes, name)) {
            auxWidget.set(name, value);
          } else if (name === 'className') {
            updateClassName(this.elementRef.current!, value as string, prevValue as string, defaultClassNames);
          } else if (name === 'style') {
            // handled by render()
          } else if (name === 'widgetRef') {
            updateRef(value, auxWidget);
          } else {
            console.warn('Unknown property %o=%o', name, value);
          }
        },
      );

      if (bindingsChanged) this._updateBindings();
    }

    componentWillUnmount(): void {
      const { auxWidget, bindings, eventSubscriptions, props } = this;
      bindings?.dispose();
      eventSubscriptions.clear();
      if (auxWidget) auxWidget.destroy();
      if (props.widgetRef) updateRef(props.widgetRef, null);
      this.auxWidget = null;
    }

    render() {
      return createElement('div', {
        ref: this.elementRef,
        style: this.props.style,
      });
    }
  };
}

// ---------------------------------------------------------------------------
// useWidgets family

interface DestructibleWidget extends WidgetInstance {
  isDestructed(): boolean;
  element?: unknown;
}

function subscribeEvents(
  widget: DestructibleWidget | null | undefined,
  events: Record<string, ((...a: unknown[]) => void) | undefined> | null | undefined,
  subscriptions: Array<() => void>,
): void {
  if (!widget || widget.isDestructed()) return;
  if (!events) return;
  for (const eventName in events) {
    const callback = events[eventName];
    if (!callback) continue;
    subscriptions.push(widget.subscribe(eventName, callback));
  }
}

function compareBindingDescription(a: unknown, b: unknown): boolean {
  if (a === b || (!a && !b)) return true;
  if (!a || !b) return false;
  for (const name in a as object) if ((a as never)[name] !== (b as never)[name]) return false;
  for (const name in b as object) if ((a as never)[name] !== (b as never)[name]) return false;
  return true;
}

function compareBindingDescriptions(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (!a.length && !b.length) return true;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++)
      if (!compareBindingDescription(a[i], b[i])) return false;
    return true;
  } else if (typeof a === 'object') {
    return compareBindingDescription(a, b);
  }
  return false;
}

/** Create a list of widgets from a list of option objects. */
export function useWidgets<W extends DestructibleWidget>(
  Widget: WidgetCtor<W>,
  options: Record<string, unknown>[],
): W[] {
  const optionsRef = useRef(options);
  const widgetsRef = useRef<W[]>([]);
  const [widgets, setWidgets] = useState<W[]>(widgetsRef.current);

  useEffect(() => {
    const currentOptions = optionsRef.current;
    let widgets = widgetsRef.current;
    const updateCount = Math.min(options.length, widgets.length);

    if (options.length !== widgets.length || widgets.some((w) => !(w instanceof Widget))) {
      widgets = widgets.slice(0);
    }

    for (let i = 0; i < updateCount; i++) {
      const widget = widgets[i];
      if (!(widget instanceof Widget)) {
        widget.destroy();
        widgets[i] = new Widget(Object.assign({}, options[i]));
      } else {
        forEachChangedProperty(
          currentOptions[i],
          options[i],
          (name) => widget.reset(name),
          (name, value) => widget.set(name, value),
        );
      }
    }

    if (updateCount < widgets.length) {
      for (let i = updateCount; i < widgets.length; i++) widgets[i].destroy();
      widgets.length = updateCount;
    } else if (updateCount < options.length) {
      widgets.length = options.length;
      for (let i = updateCount; i < options.length; i++)
        widgets[i] = new Widget(Object.assign({}, options[i]));
    }

    optionsRef.current = options;
    if (widgetsRef.current !== widgets) {
      widgetsRef.current = widgets;
      setWidgets(widgets);
    }
  }, [Widget, options, setWidgets]);

  return widgets;
}

function useBindingsForWidgets(widgets: DestructibleWidget[]): (Bindings | null)[] {
  const [descriptions, setDescriptions] = useState<(Bindings | null)[]>([]);

  useEffect(() => {
    const tmp = widgets.map((widget) => {
      if (!widget || widget.isDestructed()) return null;
      return new Bindings(widget as never, widget.element as never);
    });
    setDescriptions(tmp);
    return () => {
      tmp.forEach((b) => b?.dispose());
    };
  }, [widgets]);

  return descriptions;
}

function useBindingDescriptions(
  bindingDescriptions: (BindingDesc | BindingDesc[] | null)[],
) {
  const ref = useRef<typeof bindingDescriptions | null>(null);
  if (!compareBindingDescriptions(ref.current, bindingDescriptions))
    ref.current = bindingDescriptions;
  return ref.current!;
}

export function useWidgetsBindings(
  widgets: DestructibleWidget[],
  bindingDescriptions: (BindingDesc | BindingDesc[] | null)[] | null,
): void {
  const bindings = useBindingsForWidgets(widgets);
  let descs = bindingDescriptions || [];
  if (!Array.isArray(widgets)) throw new TypeError('expected list of widgets.');
  if (!Array.isArray(descs)) throw new TypeError('expected list of binding descriptions.');
  descs = useBindingDescriptions(descs);

  useEffect(() => {
    for (let i = 0; i < bindings.length; i++) {
      const widget = widgets[i];
      if (widget && !widget.isDestructed())
        bindings[i]?.update((descs[i] as never) || null);
    }
  }, [bindings, widgets, descs]);
}

export function useWidgetsEvents(
  widgets: DestructibleWidget[],
  events: (Record<string, (...a: unknown[]) => void> | null)[],
): void {
  useEffect(() => {
    const subscriptions: Array<() => void> = [];
    const ws = widgets || [];
    const es = events || [];
    const length = Math.min(ws.length, es.length);
    for (let i = 0; i < length; i++) subscribeEvents(ws[i], es[i], subscriptions);
    return () => subscriptions.forEach((cb) => cb());
  }, [widgets, events]);
}

export function useWidgetsWithBindingsAndEvents<W extends DestructibleWidget>(
  Widget: WidgetCtor<W>,
  widgetOptions: Record<string, unknown>[],
  bindingDescriptions: (BindingDesc | BindingDesc[] | null)[],
  events: (Record<string, (...a: unknown[]) => void> | null)[],
): W[] {
  const widgets = useWidgets(Widget, widgetOptions);
  useWidgetsBindings(widgets, bindingDescriptions);
  useWidgetsEvents(widgets, events);
  return widgets;
}
