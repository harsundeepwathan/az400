import PDFDocument from 'pdfkit';

export interface PdfTable {
  title: string;
  subtitle?: string;
  notes?: string[];
  headers: string[];
  widths: number[];
  rows: string[][];
}

/** Renders a simple tabular report as a PDF buffer. */
export function renderPdf(t: PdfTable): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', layout: 'landscape', margin: 36, info: { Title: t.title, Producer: 'Skywatch' } });
    const chunks: Buffer[] = [];
    doc.on('data', (c: Buffer) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
    doc.font('Helvetica-Bold').fontSize(16).text(t.title);
    if (t.subtitle) doc.font('Helvetica').fontSize(9).fillColor('#555').text(t.subtitle);
    doc.moveDown(0.5).fillColor('#000');
    for (const n of t.notes ?? []) doc.font('Helvetica').fontSize(8).fillColor('#444').text(n).moveDown(0.3);
    doc.moveDown(0.5).fillColor('#000');
    const x0 = doc.page.margins.left;
    const drawRow = (cells: string[], bold: boolean) => {
      const y = doc.y;
      let x = x0;
      let h = 0;
      doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(8);
      cells.forEach((c, i) => {
        const w = t.widths[i] ?? 80;
        const ch = doc.heightOfString(c, { width: w - 4 });
        h = Math.max(h, ch);
        doc.text(c, x + 2, y, { width: w - 4 });
        x += w;
      });
      doc.y = y + h + 4;
      doc.x = x0;
      if (doc.y > doc.page.height - doc.page.margins.bottom - 20) doc.addPage();
    };
    drawRow(t.headers, true);
    for (const r of t.rows) drawRow(r, false);
    doc.moveDown().font('Helvetica').fontSize(7).fillColor('#777').text(`Generated ${new Date().toISOString()} by Skywatch`);
    doc.end();
  });
}
