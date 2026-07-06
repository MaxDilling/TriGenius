import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import Privacy from "@/pages/Privacy.tsx";

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/privacy" element={<Privacy />} />
        <Route path="*" element={<Navigate to="/privacy" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
