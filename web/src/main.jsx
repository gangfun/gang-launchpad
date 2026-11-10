import React from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import '@fontsource/geist-mono/400.css'
import '@fontsource/geist-mono/500.css'
import '@fontsource/geist-mono/600.css'
import './index.css'
import { I18nProvider } from './i18n.jsx'
import Layout from './components/Layout.jsx'
import Home from './pages/Home.jsx'
import Token from './pages/Token.jsx'
import Docs from './pages/Docs.jsx'
import Me from './pages/Me.jsx'

const qc = new QueryClient({ defaultOptions: { queries: { refetchInterval: 12_000, staleTime: 5_000, retry: 1 } } })
createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <QueryClientProvider client={qc}>
      <I18nProvider>
        <BrowserRouter>
          <Routes>
            <Route element={<Layout />}>
              <Route index element={<Home />} />
              <Route path="/token/:address" element={<Token />} />
              <Route path="/docs" element={<Docs />} />
              <Route path="/me" element={<Me />} />
              <Route path="*" element={<main className="wrap"><div className="empty">404</div></main>} />
            </Route>
          </Routes>
        </BrowserRouter>
      </I18nProvider>
    </QueryClientProvider>
  </React.StrictMode>,
)
