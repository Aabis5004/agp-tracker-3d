# 🍎 Kashmir Apples - Direct from Orchards

A digital marketplace connecting Kashmir apple growers directly with buyers across India. No middlemen, fair prices, fresh produce.

![Kashmir Apples](https://via.placeholder.com/1200x600/1c1917/dc2626?text=Kashmir+Apples)

## 🎯 Vision

Empower Kashmiri apple farmers to sell directly to buyers across India, eliminating middlemen and ensuring fair prices. Growers can earn 35-50% more through direct trade.

## ✨ Features

- **For Growers:**
  - Free registration and listing
  - Set your own prices
  - Direct WhatsApp/Phone contact with buyers
  - Dashboard to track views and inquiries
  - Verified grower badge

- **For Buyers:**
  - Browse verified grower listings
  - Real-time market prices
  - Filter by variety, location, price
  - Direct contact with growers
  - Quality ratings and reviews

## 🛠️ Tech Stack

| Layer | Technology |
|-------|------------|
| Frontend | Next.js 14, React, TypeScript |
| Styling | Tailwind CSS |
| Backend | Next.js API Routes |
| Database | PostgreSQL (Supabase) |
| Auth | Supabase Auth (Phone OTP) |
| File Storage | Cloudinary |
| Deployment | Vercel / Railway |

## 🚀 Quick Start

### Prerequisites

- Node.js 18+ 
- npm or yarn
- Supabase account (free tier works)
- Cloudinary account (free tier works)

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/kashmir-apples.git
cd kashmir-apples
```

### 2. Install dependencies

```bash
npm install
```

### 3. Set up environment variables

```bash
cp .env.example .env.local
```

Edit `.env.local` with your credentials:

```env
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
DATABASE_URL=postgresql://...
```

### 4. Set up the database

```bash
# Generate Prisma client
npm run db:generate

# Push schema to database
npm run db:push

# (Optional) Seed with sample data
npm run db:seed
```

### 5. Run the development server

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

## 📁 Project Structure

```
kashmir-apples/
├── src/
│   ├── app/                 # Next.js App Router pages
│   │   ├── page.tsx         # Home page
│   │   ├── marketplace/     # Marketplace pages
│   │   ├── auth/            # Authentication pages
│   │   ├── dashboard/       # User dashboards
│   │   └── api/             # API routes
│   ├── components/          # React components
│   │   ├── home/            # Home page sections
│   │   ├── layout/          # Layout components
│   │   └── ui/              # Reusable UI components
│   └── lib/                 # Utilities and configs
│       ├── supabase.ts      # Supabase client
│       └── types.ts         # TypeScript types
├── database/
│   └── schema.prisma        # Database schema
├── public/                  # Static assets
└── package.json
```

## 🗄️ Database Setup (Supabase)

1. Create a new project at [supabase.com](https://supabase.com)
2. Go to SQL Editor and run the schema from `database/schema.sql`
3. Enable Phone Auth in Authentication > Providers
4. Copy your API keys to `.env.local`

## 📱 SMS/OTP Setup

### Option 1: MSG91 (Recommended for India)
1. Sign up at [msg91.com](https://msg91.com)
2. Create an OTP template
3. Add credentials to `.env.local`

### Option 2: Twilio
1. Sign up at [twilio.com](https://twilio.com)
2. Get a phone number
3. Add credentials to `.env.local`

## 🖼️ Image Upload Setup (Cloudinary)

1. Sign up at [cloudinary.com](https://cloudinary.com)
2. Get your cloud name and API keys
3. Add to `.env.local`

## 🚢 Deployment

### Vercel (Recommended)

1. Push your code to GitHub
2. Connect repository to Vercel
3. Add environment variables
4. Deploy!

```bash
npm run build  # Test build locally first
```

### Railway

1. Create a new project on Railway
2. Connect GitHub repository
3. Add environment variables
4. Railway auto-deploys on push

## 📊 Admin Panel

Access the admin panel at `/admin` (requires admin user type).

Features:
- Verify grower profiles
- Manage listings
- View analytics
- Update market prices

## 🔐 Security

- Phone OTP authentication
- Row Level Security (RLS) on Supabase
- Rate limiting on API routes
- Input validation with Zod

## 📈 Future Roadmap

- [ ] Mobile app (React Native)
- [ ] Payment escrow system
- [ ] Logistics partner integration
- [ ] AI-powered price predictions
- [ ] Multi-language support (Hindi, Urdu, Kashmiri)

## 🤝 Contributing

Contributions are welcome! Please read our contributing guidelines.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

- Email: support@kashmirapples.in
- WhatsApp: +91 194 123 4567
- Twitter: [@KashmirApples](https://twitter.com/KashmirApples)

## 🙏 Acknowledgments

- Kashmiri apple growers who inspired this project
- The open-source community
- Supabase, Vercel, and Cloudinary teams

---

Made with ❤️ for Kashmiri farmers

**[www.kashmirapples.in](https://kashmirapples.in)**
