/// <reference types="vite/client" />

declare module '*.md' {
  import type { ComponentType } from 'react'

  const Component: ComponentType
  export default Component
  export const headings: Array<{
    depth: number
    slug: string
    text: string
  }>
}

declare module 'virtual:api-last-updated' {
  export const lastUpdatedByApiSection: Record<string, string>
}
