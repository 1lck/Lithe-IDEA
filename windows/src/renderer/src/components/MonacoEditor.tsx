import { useRef, useEffect } from 'react'
import * as monaco from 'monaco-editor'
import './MonacoEditor.css'

interface Props {
  content: string
  language: string
  onChange: (value: string) => void
}

export function MonacoEditor({ content, language, onChange }: Props): JSX.Element {
  const containerRef = useRef<HTMLDivElement>(null)
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null)

  useEffect(() => {
    if (!containerRef.current) return

    monaco.editor.defineTheme('lithe-idea', {
      base: 'vs-dark',
      inherit: true,
      rules: [
        { token: 'comment', foreground: '7a7e85', fontStyle: 'italic' },
        { token: 'keyword', foreground: 'cf8e6d' },
        { token: 'string', foreground: '6aab73' },
        { token: 'number', foreground: '2aacb8' },
        { token: 'type', foreground: '56a8f5' },
        { token: 'class', foreground: '56a8f5' },
        { token: 'identifier', foreground: 'bcbec4' },
        { token: 'delimiter', foreground: 'bcbec4' },
        { token: 'annotation', foreground: 'bbb529' }
      ],
      colors: {
        'editor.background': '#131416',
        'editor.foreground': '#dbdbdb',
        'editor.lineHighlightBackground': '#1a1c1f',
        'editor.selectionBackground': '#2b4a7d',
        'editor.inactiveSelectionBackground': '#2b4a7d66',
        'editorCursor.foreground': '#dbdbdb',
        'editorLineNumber.foreground': '#4a4d52',
        'editorLineNumber.activeForeground': '#9a9da3',
        'editorIndentGuide.background': '#ffffff14',
        'editorIndentGuide.activeBackground': '#ffffff3d',
        'editorWidget.background': '#222428',
        'editorWidget.border': '#ffffff22',
        'editorSuggestWidget.background': '#222428',
        'editorSuggestWidget.selectedBackground': '#2b4a7d',
        'minimap.background': '#131416',
        'scrollbarSlider.background': '#ffffff14',
        'scrollbarSlider.hoverBackground': '#ffffff22',
        'scrollbarSlider.activeBackground': '#ffffff30',
        'editorGutter.background': '#131416'
      }
    })
    monaco.editor.setTheme('lithe-idea')

    const editor = monaco.editor.create(containerRef.current, {
      value: content,
      language,
      theme: 'lithe-idea',
      automaticLayout: true,
      minimap: { enabled: true, scale: 1, showSlider: 'mouseover' },
      fontSize: 13,
      fontFamily: "'JetBrains Mono', 'Cascadia Code', Consolas, monospace",
      fontLigatures: true,
      lineNumbers: 'on',
      renderLineHighlight: 'line',
      scrollBeyondLastLine: false,
      padding: { top: 4, bottom: 4 },
      bracketPairColorization: { enabled: true },
      guides: { indentation: true, bracketPairs: false },
      smoothScrolling: true,
      cursorBlinking: 'smooth',
      cursorSmoothCaretAnimation: 'on',
      roundedSelection: false,
      overviewRulerBorder: false,
      scrollbar: { verticalScrollbarSize: 8, horizontalScrollbarSize: 8 }
    })

    editorRef.current = editor
    editor.onDidChangeModelContent(() => {
      onChange(editor.getValue())
    })

    return () => {
      editor.dispose()
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  return <div className="monaco-container" ref={containerRef} />
}
