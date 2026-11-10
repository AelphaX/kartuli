import React, { useState, useEffect, useMemo, useRef } from 'react';
import { initializeApp } from 'firebase/app';
import { 
    getAuth, signInAnonymously, signInWithCustomToken, onAuthStateChanged 
} from 'firebase/auth';
import { 
    getFirestore, doc, getDoc, setDoc, onSnapshot, collection, 
    addDoc, updateDoc, deleteDoc, getDocs, writeBatch 
} from 'firebase/firestore';
import { 
    Flame, Book, Plus, Settings, Sun, Moon, ArrowLeft, 
    Check, X, RefreshCw, Trash2, Edit2, Play, BrainCircuit, Loader2, Sparkles, AlertCircle
} from 'lucide-react';

// --- Firebase Initialization ---
const firebaseConfig = typeof __firebase_config !== 'undefined' ? JSON.parse(__firebase_config) : {};
const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);
const appId = typeof __app_id !== 'undefined' ? __app_id : 'kartvelearn-default';

// --- Global CSS for 3D Flip Animation ---
const styles = `
  .perspective-1000 { perspective: 1000px; }
  .transform-style-3d { transform-style: preserve-3d; }
  .backface-hidden { backface-visibility: hidden; }
  .rotate-y-180 { transform: rotateY(180deg); }
  .flip-card-inner {
    transition: transform 0.6s cubic-bezier(0.4, 0.2, 0.2, 1);
  }
`;
if (typeof document !== 'undefined') {
  const styleSheet = document.createElement("style");
  styleSheet.innerText = styles;
  document.head.appendChild(styleSheet);
}

// --- Helper: SRS Algorithm (Simplified SuperMemo-2) ---
// Returns updated SRS fields based on user rating (0: Nochmal, 1: Schwer, 2: Gut, 3: Einfach)
function calculateNextReview(card, quality) {
    let { ease = 2.5, interval = 0, repetitions = 0 } = card;

    if (quality === 0) { // Nochmal
        repetitions = 0;
        interval = 0; // Same day review
    } else {
        if (repetitions === 0) {
            interval = 1;
        } else if (repetitions === 1) {
            interval = 6;
        } else {
            interval = Math.round(interval * ease);
        }
        repetitions++;
    }

    if (quality === 1) ease = Math.max(1.3, ease - 0.15); // Schwer
    if (quality === 3) ease = ease + 0.15; // Einfach

    const now = new Date();
    // If interval is 0 (Nochmal), set review to now, else set to start of the day + interval
    let nextReview = now.getTime();
    if (interval > 0) {
        now.setHours(0, 0, 0, 0);
        nextReview = now.getTime() + (interval * 24 * 60 * 60 * 1000);
    }

    return { ease, interval, repetitions, nextReview };
}

// --- Main App Component ---
export default function KartveLearnApp() {
    const [user, setUser] = useState(null);
    const [profile, setProfile] = useState({ theme: 'dark', dailyGoal: 20, streak: 0, lastStudyDate: 0, dailyStudied: 0 });
    const [decks, setDecks] = useState([]);
    const [cards, setCards] = useState([]);
    
    const [activeTab, setActiveTab] = useState('dashboard'); // dashboard, study, create, settings, deck-manage
    const [activeDeck, setActiveDeck] = useState(null);
    const [isLoading, setIsLoading] = useState(true);

    // --- Authentication ---
    useEffect(() => {
        const initAuth = async () => {
            try {
                if (typeof __initial_auth_token !== 'undefined' && __initial_auth_token) {
                    await signInWithCustomToken(auth, __initial_auth_token);
                } else {
                    await signInAnonymously(auth);
                }
            } catch (err) {
                console.error("Auth error:", err);
            }
        };
        initAuth();

        const unsubscribe = onAuthStateChanged(auth, (u) => {
            setUser(u);
            if (!u) setIsLoading(false);
        });
        return () => unsubscribe();
    }, []);

    // --- Data Fetching & Sync ---
    useEffect(() => {
        if (!user) return;
        setIsLoading(true);
        const userId = user.uid;

        // 1. Profile Sync
        const profileRef = doc(db, 'artifacts', appId, 'users', userId, 'profile', 'main');
        const unsubProfile = onSnapshot(profileRef, (docSnap) => {
            if (docSnap.exists()) {
                const data = docSnap.data();
                // Check daily streak and reset daily studied if it's a new day
                const now = new Date();
                const todayStr = now.toDateString();
                const lastDate = new Date(data.lastStudyDate || 0);
                
                let updatedProfile = { ...data };
                if (lastDate.toDateString() !== todayStr) {
                     updatedProfile.dailyStudied = 0;
                     // Streak logic: if last study was > 1 day ago, streak breaks (unless it was yesterday)
                     const yesterday = new Date(now);
                     yesterday.setDate(yesterday.getDate() - 1);
                     if (lastDate.toDateString() !== yesterday.toDateString() && lastDate.getTime() !== 0) {
                         // Missed a day
                         // updatedProfile.streak = 0; // Keeping streak simple for now: it updates on study action
                     }
                }
                setProfile(updatedProfile);
            } else {
                setDoc(profileRef, profile); // Create initial
            }
        }, (err) => console.error("Profile sync error", err));

        // 2. Decks Sync
        const decksRef = collection(db, 'artifacts', appId, 'users', userId, 'decks');
        const unsubDecks = onSnapshot(decksRef, (snap) => {
            const loadedDecks = snap.docs.map(d => ({ id: d.id, ...d.data() }));
            if (loadedDecks.length === 0 && !isLoading) {
                seedDefaultDecks(userId);
            }
            setDecks(loadedDecks.sort((a,b) => b.createdAt - a.createdAt));
        }, (err) => console.error("Decks sync error", err));

        // 3. Cards Sync
        const cardsRef = collection(db, 'artifacts', appId, 'users', userId, 'cards');
        const unsubCards = onSnapshot(cardsRef, (snap) => {
            setCards(snap.docs.map(d => ({ id: d.id, ...d.data() })));
            setIsLoading(false);
        }, (err) => console.error("Cards sync error", err));

        return () => {
            unsubProfile();
            unsubDecks();
            unsubCards();
        };
    }, [user]);

    // --- Helper: Seed Default Data ---
    const seedDefaultDecks = async (userId) => {
        try {
            const batch = writeBatch(db);
            const decksRef = collection(db, 'artifacts', appId, 'users', userId, 'decks');
            const cardsRef = collection(db, 'artifacts', appId, 'users', userId, 'cards');

            const basicsRef = doc(decksRef);
            batch.set(basicsRef, { name: "Grundlagen", description: "Die wichtigsten ersten Wörter", createdAt: Date.now() });
            
            const foodRef = doc(decksRef);
            batch.set(foodRef, { name: "Essen & Trinken", description: "Alles rund um georgisches Essen", createdAt: Date.now() });

            const initialCards = [
                { deckId: basicsRef.id, georgian: "გამარჯობა", german: "Hallo", phonetics: "gamarjoba", emoji: "👋" },
                { deckId: basicsRef.id, georgian: "მადლობა", german: "Danke", phonetics: "madloba", emoji: "🙏" },
                { deckId: basicsRef.id, georgian: "ნახვამდის", german: "Tschüss", phonetics: "nakhvamdis", emoji: "🚶‍♂️" },
                { deckId: basicsRef.id, georgian: "დიახ", german: "Ja", phonetics: "diakh", emoji: "✅" },
                { deckId: basicsRef.id, georgian: "არა", german: "Nein", phonetics: "ara", emoji: "❌" },
                { deckId: foodRef.id, georgian: "წყალი", german: "Wasser", phonetics: "tsqali", emoji: "💧" },
                { deckId: foodRef.id, georgian: "ხაჭაპური", german: "Käsebrot", phonetics: "khachapuri", emoji: "🧀" },
                { deckId: foodRef.id, georgian: "ღვინო", german: "Wein", phonetics: "ghvino", emoji: "🍷" },
                { deckId: foodRef.id, georgian: "ხინკალი", german: "Teigtasche", phonetics: "khinkali", emoji: "🥟" }
            ];

            initialCards.forEach(card => {
                const cRef = doc(cardsRef);
                batch.set(cRef, { ...card, ease: 2.5, interval: 0, repetitions: 0, nextReview: 0, createdAt: Date.now() });
            });

            await batch.commit();
        } catch (err) {
            console.error("Error seeding default data", err);
        }
    };

    // --- Profile Updates ---
    const updateProfile = async (updates) => {
        if (!user) return;
        const profileRef = doc(db, 'artifacts', appId, 'users', user.uid, 'profile', 'main');
        await updateDoc(profileRef, updates);
    };

    const toggleTheme = () => {
        updateProfile({ theme: profile.theme === 'dark' ? 'light' : 'dark' });
    };

    const recordStudyAction = async () => {
        const now = new Date();
        const last = new Date(profile.lastStudyDate || 0);
        let newStreak = profile.streak;
        
        now.setHours(0,0,0,0);
        last.setHours(0,0,0,0);
        
        const diffTime = Math.abs(now - last);
        const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24)); 

        if (diffDays === 1) {
            newStreak += 1;
        } else if (diffDays > 1) {
            newStreak = 1;
        } else if (profile.streak === 0) {
            newStreak = 1;
        } // diffDays === 0 means already studied today, streak remains same

        const newStudied = profile.dailyStudied + 1;
        await updateProfile({
            streak: newStreak,
            lastStudyDate: Date.now(),
            dailyStudied: newStudied
        });
    };

    // --- Derived Data ---
    const nowMs = Date.now();
    const decksWithDueCounts = useMemo(() => {
        return decks.map(deck => {
            const deckCards = cards.filter(c => c.deckId === deck.id);
            const dueCards = deckCards.filter(c => c.nextReview <= nowMs);
            return { ...deck, totalCards: deckCards.length, dueCount: dueCards.length };
        });
    }, [decks, cards, nowMs]);

    const allDueCount = decksWithDueCounts.reduce((acc, d) => acc + d.dueCount, 0);

    // --- UI Context Wrapper ---
    return (
        <div className={`min-h-screen transition-colors duration-300 ${profile.theme === 'dark' ? 'dark bg-slate-950 text-slate-100' : 'bg-slate-50 text-slate-900'}`}>
            {isLoading ? (
                <div className="flex h-screen items-center justify-center">
                    <Loader2 className="animate-spin w-8 h-8 text-indigo-500" />
                </div>
            ) : (
                <div className="max-w-md mx-auto h-screen flex flex-col relative bg-white dark:bg-slate-900 shadow-xl overflow-hidden">
                    {/* Header */}
                    <header className="px-6 py-4 flex justify-between items-center border-b border-slate-100 dark:border-slate-800 shrink-0">
                        <div className="flex items-center space-x-2" onClick={() => setActiveTab('dashboard')}>
                            <div className="bg-indigo-500 p-2 rounded-xl">
                                <Book className="w-5 h-5 text-white" />
                            </div>
                            <h1 className="font-bold text-xl tracking-tight cursor-pointer">KartveLearn</h1>
                        </div>
                        <div className="flex items-center space-x-4">
                            <div className="flex items-center space-x-1 bg-orange-100 dark:bg-orange-950/50 text-orange-600 dark:text-orange-500 px-3 py-1 rounded-full font-bold text-sm">
                                <Flame className={`w-4 h-4 ${profile.streak > 0 ? 'fill-current' : ''}`} />
                                <span>{profile.streak}</span>
                            </div>
                            <button onClick={() => setActiveTab('settings')} className="text-slate-400 hover:text-slate-600 dark:hover:text-slate-200">
                                <Settings className="w-5 h-5" />
                            </button>
                        </div>
                    </header>

                    {/* Main Content Area */}
                    <main className="flex-1 overflow-y-auto overflow-x-hidden">
                        {activeTab === 'dashboard' && (
                            <DashboardView 
                                profile={profile} 
                                decks={decksWithDueCounts} 
                                allDueCount={allDueCount}
                                onStartStudy={(deckId) => {
                                    setActiveDeck(deckId);
                                    setActiveTab('study');
                                }}
                                onManageDeck={(deck) => {
                                    setActiveDeck(deck.id);
                                    setActiveTab('deck-manage');
                                }}
                                onCreateDeck={() => setActiveTab('create')}
                            />
                        )}
                        {activeTab === 'study' && (
                            <StudyView 
                                user={user}
                                deckId={activeDeck} 
                                allCards={cards} 
                                onFinish={() => setActiveTab('dashboard')}
                                onAction={recordStudyAction}
                            />
                        )}
                        {activeTab === 'create' && (
                            <CreateDeckView 
                                user={user}
                                onBack={() => setActiveTab('dashboard')} 
                            />
                        )}
                        {activeTab === 'deck-manage' && (
                            <DeckManageView
                                user={user}
                                deckId={activeDeck}
                                decks={decks}
                                cards={cards}
                                onBack={() => setActiveTab('dashboard')}
                            />
                        )}
                        {activeTab === 'settings' && (
                            <SettingsView 
                                profile={profile} 
                                onUpdate={updateProfile} 
                                toggleTheme={toggleTheme} 
                                onBack={() => setActiveTab('dashboard')} 
                            />
                        )}
                    </main>
                </div>
            )}
        </div>
    );
}

// --- Dashboard View ---
function DashboardView({ profile, decks, allDueCount, onStartStudy, onManageDeck, onCreateDeck }) {
    const progressPercent = Math.min(100, (profile.dailyStudied / profile.dailyGoal) * 100);

    return (
        <div className="p-6 space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
            {/* Daily Goal Progress */}
            <div className="bg-gradient-to-br from-indigo-500 to-purple-600 rounded-3xl p-6 text-white shadow-lg relative overflow-hidden">
                <div className="absolute top-0 right-0 p-4 opacity-20">
                    <Sparkles className="w-24 h-24" />
                </div>
                <h2 className="text-xl font-bold mb-1">Tagesziel</h2>
                <p className="text-indigo-100 text-sm mb-4">
                    {profile.dailyStudied} von {profile.dailyGoal} Karten gelernt
                </p>
                <div className="h-3 w-full bg-black/20 rounded-full overflow-hidden">
                    <div 
                        className="h-full bg-white rounded-full transition-all duration-1000 ease-out relative"
                        style={{ width: `${progressPercent}%` }}
                    >
                         <div className="absolute inset-0 bg-white/50 animate-pulse"></div>
                    </div>
                </div>
                {progressPercent >= 100 && (
                    <div className="mt-3 flex items-center text-sm font-medium bg-white/20 inline-block px-3 py-1 rounded-full">
                        <Check className="w-4 h-4 mr-1" /> Ziel erreicht!
                    </div>
                )}
            </div>

            {/* Decks List */}
            <div>
                <div className="flex justify-between items-end mb-4">
                    <h3 className="text-lg font-bold text-slate-800 dark:text-slate-200">Deine Decks</h3>
                    <span className="text-sm font-medium text-slate-500 dark:text-slate-400 bg-slate-100 dark:bg-slate-800 px-2 py-1 rounded-md">
                        {allDueCount} fällig
                    </span>
                </div>
                
                <div className="space-y-3">
                    {decks.map(deck => (
                        <div key={deck.id} className="group bg-white dark:bg-slate-800/50 border border-slate-200 dark:border-slate-800 rounded-2xl p-4 flex items-center justify-between shadow-sm hover:shadow-md transition-all">
                            <div className="flex-1 min-w-0 pr-4 cursor-pointer" onClick={() => onManageDeck(deck)}>
                                <h4 className="font-bold text-slate-800 dark:text-slate-100 truncate">{deck.name}</h4>
                                <div className="text-sm text-slate-500 dark:text-slate-400 mt-1 flex space-x-3">
                                    <span>{deck.totalCards} Karten</span>
                                </div>
                            </div>
                            
                            <button 
                                onClick={() => deck.dueCount > 0 ? onStartStudy(deck.id) : null}
                                disabled={deck.dueCount === 0}
                                className={`shrink-0 flex flex-col items-center justify-center w-16 h-16 rounded-xl transition-all ${
                                    deck.dueCount > 0 
                                    ? 'bg-indigo-100 text-indigo-700 dark:bg-indigo-900/50 dark:text-indigo-300 hover:scale-105 active:scale-95' 
                                    : 'bg-slate-100 text-slate-400 dark:bg-slate-800/50 dark:text-slate-500'
                                }`}
                            >
                                <span className="font-bold text-xl">{deck.dueCount}</span>
                                <span className="text-[10px] uppercase font-bold tracking-wider">Fällig</span>
                            </button>
                        </div>
                    ))}
                    
                    <button 
                        onClick={onCreateDeck}
                        className="w-full py-4 border-2 border-dashed border-slate-300 dark:border-slate-700 text-slate-500 dark:text-slate-400 rounded-2xl hover:border-indigo-400 hover:text-indigo-500 transition-colors flex items-center justify-center font-medium"
                    >
                        <Plus className="w-5 h-5 mr-2" /> Neues Deck erstellen
                    </button>
                </div>
            </div>
        </div>
    );
}

// --- Study View (Flashcards) ---
function StudyView({ user, deckId, allCards, onFinish, onAction }) {
    const [queue, setQueue] = useState([]);
    const [currentIndex, setCurrentIndex] = useState(0);
    const [isFlipped, setIsFlipped] = useState(false);
    
    // Initialize queue on mount
    useEffect(() => {
        const now = Date.now();
        // If deckId is null, study all due cards. Otherwise, filter by deck.
        let due = allCards.filter(c => c.nextReview <= now);
        if (deckId) {
            due = due.filter(c => c.deckId === deckId);
        }
        
        // Shuffle queue
        const shuffled = [...due].sort(() => Math.random() - 0.5);
        setQueue(shuffled);
    }, [deckId, allCards]);

    const currentCard = queue[currentIndex];

    const handleRating = async (quality) => {
        if (!user || !currentCard) return;

        // Calculate new SRS values
        const updates = calculateNextReview(currentCard, quality);
        
        // Optimistic UI update - prepare next card immediately
        onAction(); // update streak/daily goal
        
        // Fire async update
        const cardRef = doc(db, 'artifacts', appId, 'users', user.uid, 'cards', currentCard.id);
        updateDoc(cardRef, updates).catch(err => console.error("Error updating card", err));

        // Move to next card
        setIsFlipped(false);
        setTimeout(() => {
            setCurrentIndex(prev => prev + 1);
        }, 150); // slight delay to allow flip animation to reset visually if needed, though we hide it.
    };

    if (queue.length === 0) {
        return (
            <div className="flex flex-col items-center justify-center h-full p-6 text-center animate-in fade-in zoom-in duration-500">
                <div className="w-24 h-24 bg-green-100 dark:bg-green-900/30 text-green-500 rounded-full flex items-center justify-center mb-6">
                    <Check className="w-12 h-12" />
                </div>
                <h2 className="text-2xl font-bold mb-2">Alles erledigt!</h2>
                <p className="text-slate-500 dark:text-slate-400 mb-8">Du hast keine fälligen Karten mehr für heute in diesem Deck.</p>
                <button onClick={onFinish} className="bg-indigo-600 text-white font-bold py-3 px-8 rounded-full shadow-lg shadow-indigo-200 dark:shadow-none hover:bg-indigo-700 transition-colors">
                    Zurück zur Übersicht
                </button>
            </div>
        );
    }

    if (!currentCard) {
        return (
            <div className="flex flex-col items-center justify-center h-full">
                 <h2 className="text-2xl font-bold mb-6">Geschafft!</h2>
                 <button onClick={onFinish} className="bg-indigo-600 text-white font-bold py-3 px-8 rounded-full">Zurück</button>
            </div>
        )
    }

    return (
        <div className="flex flex-col h-full bg-slate-100 dark:bg-slate-950">
            {/* Top Bar */}
            <div className="p-4 flex items-center justify-between shrink-0">
                <button onClick={onFinish} className="p-2 -ml-2 text-slate-500 hover:text-slate-800 dark:hover:text-slate-200">
                    <X className="w-6 h-6" />
                </button>
                <div className="flex-1 mx-4">
                    <div className="h-2 bg-slate-200 dark:bg-slate-800 rounded-full overflow-hidden">
                        <div 
                            className="h-full bg-indigo-500 transition-all duration-300"
                            style={{ width: `${(currentIndex / queue.length) * 100}%` }}
                        />
                    </div>
                </div>
                <span className="text-sm font-bold text-slate-500">{currentIndex + 1} / {queue.length}</span>
            </div>

            {/* Flashcard Area */}
            <div className="flex-1 relative perspective-1000 p-6 flex flex-col justify-center">
                <div 
                    className={`relative w-full h-[60vh] max-h-[500px] transform-style-3d flip-card-inner cursor-pointer rounded-3xl shadow-xl ${isFlipped ? 'rotate-y-180' : ''}`}
                    onClick={() => !isFlipped && setIsFlipped(true)}
                >
                    {/* Front */}
                    <div className="absolute inset-0 backface-hidden bg-white dark:bg-slate-800 rounded-3xl border border-slate-200 dark:border-slate-700 flex flex-col items-center justify-center p-8 text-center">
                        <span className="text-slate-400 text-sm font-bold uppercase tracking-widest mb-8">Georgisch</span>
                        <h2 className="text-6xl md:text-7xl font-bold text-slate-800 dark:text-slate-100" style={{ fontFamily: "Sylfaen, Arial, sans-serif" }}>
                            {currentCard.georgian}
                        </h2>
                        <div className="absolute bottom-8 text-slate-400 text-sm flex flex-col items-center animate-pulse">
                            <RefreshCw className="w-5 h-5 mb-1" />
                            Tippen zum Aufdecken
                        </div>
                    </div>

                    {/* Back */}
                    <div className="absolute inset-0 backface-hidden bg-white dark:bg-slate-800 rounded-3xl border border-indigo-200 dark:border-indigo-900/50 flex flex-col items-center justify-center p-8 text-center rotate-y-180">
                         {currentCard.emoji && (
                             <div className="text-6xl mb-6">{currentCard.emoji}</div>
                         )}
                         <span className="text-indigo-500 font-bold mb-2">{currentCard.phonetics}</span>
                         <h2 className="text-4xl font-bold text-slate-800 dark:text-slate-100">
                             {currentCard.german}
                         </h2>
                         
                         {/* Display SRS Data subtly */}
                         <div className="absolute top-4 right-4 text-xs text-slate-400 flex items-center">
                             <BrainCircuit className="w-3 h-3 mr-1" /> 
                             Level {currentCard.repetitions || 0}
                         </div>
                    </div>
                </div>
            </div>

            {/* SRS Controls */}
            <div className={`p-6 shrink-0 transition-all duration-300 transform ${isFlipped ? 'translate-y-0 opacity-100' : 'translate-y-10 opacity-0 pointer-events-none'}`}>
                <div className="grid grid-cols-4 gap-2">
                    <SRSButton color="red" label="Nochmal" sub="< 1m" onClick={() => handleRating(0)} />
                    <SRSButton color="orange" label="Schwer" sub="Tage" onClick={() => handleRating(1)} />
                    <SRSButton color="green" label="Gut" sub="Tage" onClick={() => handleRating(2)} />
                    <SRSButton color="blue" label="Einfach" sub="Wochen" onClick={() => handleRating(3)} />
                </div>
            </div>
        </div>
    );
}

function SRSButton({ color, label, sub, onClick }) {
    const colorClasses = {
        red: "bg-red-100 text-red-700 hover:bg-red-200 dark:bg-red-950/30 dark:text-red-400 dark:hover:bg-red-900/50",
        orange: "bg-orange-100 text-orange-700 hover:bg-orange-200 dark:bg-orange-950/30 dark:text-orange-400 dark:hover:bg-orange-900/50",
        green: "bg-emerald-100 text-emerald-700 hover:bg-emerald-200 dark:bg-emerald-950/30 dark:text-emerald-400 dark:hover:bg-emerald-900/50",
        blue: "bg-blue-100 text-blue-700 hover:bg-blue-200 dark:bg-blue-950/30 dark:text-blue-400 dark:hover:bg-blue-900/50"
    };

    return (
        <button onClick={(e) => { e.stopPropagation(); onClick(); }} className={`flex flex-col items-center justify-center py-3 rounded-xl transition-colors ${colorClasses[color]}`}>
            <span className="font-bold text-sm md:text-base">{label}</span>
            {/* Real calculation of next interval is complex to show dynamically without executing algorithm, keeping static abstract for UI */}
        </button>
    );
}

// --- Deck Manage View ---
function DeckManageView({ user, deckId, decks, cards, onBack }) {
    const deck = decks.find(d => d.id === deckId);
    const deckCards = cards.filter(c => c.deckId === deckId).sort((a,b) => b.createdAt - a.createdAt);
    const [isDeleting, setIsDeleting] = useState(false);

    const [newCard, setNewCard] = useState({ georgian: '', german: '', phonetics: '', emoji: '' });

    if (!deck) return null;

    const handleAddCard = async (e) => {
        e.preventDefault();
        if (!user || !newCard.georgian || !newCard.german) return;
        
        try {
            const cardsRef = collection(db, 'artifacts', appId, 'users', user.uid, 'cards');
            await addDoc(cardsRef, {
                ...newCard,
                deckId,
                ease: 2.5, interval: 0, repetitions: 0, nextReview: 0,
                createdAt: Date.now()
            });
            setNewCard({ georgian: '', german: '', phonetics: '', emoji: '' });
        } catch (err) {
            console.error(err);
        }
    };

    const handleDeleteCard = async (cardId) => {
        if (!user) return;
        await deleteDoc(doc(db, 'artifacts', appId, 'users', user.uid, 'cards', cardId));
    };

    const handleDeleteDeck = async () => {
        if (!user) return;
        setIsDeleting(true);
        // Delete all cards first
        const batch = writeBatch(db);
        deckCards.forEach(c => {
            batch.delete(doc(db, 'artifacts', appId, 'users', user.uid, 'cards', c.id));
        });
        batch.delete(doc(db, 'artifacts', appId, 'users', user.uid, 'decks', deck.id));
        await batch.commit();
        onBack();
    };

    return (
        <div className="flex flex-col h-full animate-in fade-in duration-300">
            <header className="p-4 flex items-center border-b border-slate-100 dark:border-slate-800">
                <button onClick={onBack} className="p-2 -ml-2 text-slate-500 hover:text-slate-800 dark:hover:text-slate-200">
                    <ArrowLeft className="w-6 h-6" />
                </button>
                <h2 className="font-bold text-lg ml-2 flex-1 truncate">{deck.name}</h2>
                <button onClick={handleDeleteDeck} disabled={isDeleting} className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-950/30 rounded-lg">
                    <Trash2 className="w-5 h-5" />
                </button>
            </header>

            <div className="flex-1 overflow-y-auto p-4 space-y-6">
                {/* Add Card Form */}
                <form onSubmit={handleAddCard} className="bg-slate-50 dark:bg-slate-800/50 p-4 rounded-2xl border border-slate-200 dark:border-slate-700">
                    <h3 className="font-bold mb-3 text-sm text-slate-500 uppercase tracking-wider">Neue Karte hinzufügen</h3>
                    <div className="grid grid-cols-2 gap-3 mb-3">
                        <input required placeholder="Georgisch (z.B. წყალი)" value={newCard.georgian} onChange={e => setNewCard({...newCard, georgian: e.target.value})} className="bg-white dark:bg-slate-900 border border-slate-300 dark:border-slate-600 rounded-lg p-2 text-sm focus:ring-2 focus:ring-indigo-500 outline-none" />
                        <input required placeholder="Deutsch (z.B. Wasser)" value={newCard.german} onChange={e => setNewCard({...newCard, german: e.target.value})} className="bg-white dark:bg-slate-900 border border-slate-300 dark:border-slate-600 rounded-lg p-2 text-sm focus:ring-2 focus:ring-indigo-500 outline-none" />
                        <input placeholder="Aussprache (Optional)" value={newCard.phonetics} onChange={e => setNewCard({...newCard, phonetics: e.target.value})} className="bg-white dark:bg-slate-900 border border-slate-300 dark:border-slate-600 rounded-lg p-2 text-sm focus:ring-2 focus:ring-indigo-500 outline-none" />
                        <input placeholder="Emoji (z.B. 💧)" value={newCard.emoji} onChange={e => setNewCard({...newCard, emoji: e.target.value})} className="bg-white dark:bg-slate-900 border border-slate-300 dark:border-slate-600 rounded-lg p-2 text-sm focus:ring-2 focus:ring-indigo-500 outline-none" />
                    </div>
                    <button type="submit" className="w-full bg-indigo-100 text-indigo-700 dark:bg-indigo-900/50 dark:text-indigo-300 font-bold py-2 rounded-lg hover:bg-indigo-200 dark:hover:bg-indigo-800/50 transition-colors flex items-center justify-center">
                        <Plus className="w-4 h-4 mr-1" /> Hinzufügen
                    </button>
                </form>

                {/* Cards List */}
                <div className="space-y-2">
                    {deckCards.map(c => (
                        <div key={c.id} className="flex items-center justify-between bg-white dark:bg-slate-800 p-3 rounded-xl border border-slate-200 dark:border-slate-700 shadow-sm">
                            <div className="flex items-center space-x-3 truncate">
                                <div className="text-2xl w-8 text-center">{c.emoji}</div>
                                <div className="truncate">
                                    <div className="font-bold text-slate-800 dark:text-slate-100">{c.georgian}</div>
                                    <div className="text-sm text-slate-500">{c.german}</div>
                                </div>
                            </div>
                            <button onClick={() => handleDeleteCard(c.id)} className="text-slate-400 hover:text-red-500 p-2 shrink-0">
                                <Trash2 className="w-4 h-4" />
                            </button>
                        </div>
                    ))}
                    {deckCards.length === 0 && (
                        <div className="text-center text-slate-500 py-8">Dieses Deck ist noch leer.</div>
                    )}
                </div>
            </div>
        </div>
    );
}


// --- Create Deck (Gemini Integration) ---
function CreateDeckView({ user, onBack }) {
    const [mode, setMode] = useState('gemini'); // 'gemini' or 'manual'
    const [topic, setTopic] = useState('');
    const [deckName, setDeckName] = useState('');
    const [isGenerating, setIsGenerating] = useState(false);
    const [error, setError] = useState('');

    const handleCreateManual = async (e) => {
        e.preventDefault();
        if (!user || !deckName) return;
        try {
            await addDoc(collection(db, 'artifacts', appId, 'users', user.uid, 'decks'), {
                name: deckName,
                description: "Manuell erstellt",
                createdAt: Date.now()
            });
            onBack();
        } catch (err) {
            console.error(err);
        }
    };

    const handleGenerateAI = async (e) => {
        e.preventDefault();
        if (!user || !topic) return;
        setIsGenerating(true);
        setError('');

        try {
            const prompt = `Du bist ein Experte für die georgische Sprache. Erstelle eine Liste von exakt 10 nützlichen Vokabeln zum Thema "${topic}". 
            Antworte AUSSCHLIESSLICH im reinen JSON Format, als ein Array von Objekten. Keine Markdown-Block-Syntax (keine \`\`\`json), kein einleitender Text. 
            Format jedes Objekts:
            {"georgian": "das georgische Wort in originaler Schrift", "german": "deutsche Übersetzung", "phonetics": "Lautschrift mit lateinischen Buchstaben", "emoji": "ein einzelnes passendes Emoji"}`;

            const payload = {
                contents: [{ parts: [{ text: prompt }] }],
            };

            const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key=`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            if (!response.ok) throw new Error("Fehler bei der API Anfrage");
            const data = await response.json();
            
            const rawText = data.candidates?.[0]?.content?.parts?.[0]?.text || '';
            let jsonString = rawText.trim();
            // Try to strip backticks if AI ignores prompt instructions
            if (jsonString.startsWith('```')) {
                jsonString = jsonString.replace(/^```(json)?\n/, '').replace(/\n```$/, '');
            }

            const cardsData = JSON.parse(jsonString);

            if (!Array.isArray(cardsData)) throw new Error("Ungültiges JSON Format erhalten");

            // Save to Firebase
            const batch = writeBatch(db);
            
            // Create Deck
            const deckRef = doc(collection(db, 'artifacts', appId, 'users', user.uid, 'decks'));
            batch.set(deckRef, {
                name: `KI: ${topic.charAt(0).toUpperCase() + topic.slice(1)}`,
                description: `Automatisch generiert zum Thema: ${topic}`,
                createdAt: Date.now()
            });

            // Create Cards
            const cardsColRef = collection(db, 'artifacts', appId, 'users', user.uid, 'cards');
            cardsData.forEach(card => {
                const cRef = doc(cardsColRef);
                batch.set(cRef, {
                    ...card,
                    deckId: deckRef.id,
                    ease: 2.5, interval: 0, repetitions: 0, nextReview: 0,
                    createdAt: Date.now()
                });
            });

            await batch.commit();
            onBack();

        } catch (err) {
            console.error("Gemini Generation Error:", err);
            setError("Die Vokabeln konnten nicht generiert werden. Bitte versuche ein anderes Thema oder überprüfe deine Verbindung.");
        } finally {
            setIsGenerating(false);
        }
    };

    return (
        <div className="flex flex-col h-full animate-in fade-in slide-in-from-right-4 duration-300">
             <header className="p-4 flex items-center border-b border-slate-100 dark:border-slate-800">
                <button onClick={onBack} disabled={isGenerating} className="p-2 -ml-2 text-slate-500 hover:text-slate-800 dark:hover:text-slate-200">
                    <ArrowLeft className="w-6 h-6" />
                </button>
                <h2 className="font-bold text-lg ml-2">Neues Deck</h2>
            </header>

            <div className="p-6">
                {/* Tabs */}
                <div className="flex bg-slate-100 dark:bg-slate-800 p-1 rounded-xl mb-8">
                    <button 
                        onClick={() => setMode('gemini')}
                        className={`flex-1 py-2 text-sm font-bold rounded-lg transition-colors flex items-center justify-center ${mode === 'gemini' ? 'bg-white dark:bg-slate-700 shadow-sm text-indigo-600 dark:text-indigo-400' : 'text-slate-500'}`}
                    >
                        <Sparkles className="w-4 h-4 mr-2" /> KI-Generator
                    </button>
                    <button 
                        onClick={() => setMode('manual')}
                        className={`flex-1 py-2 text-sm font-bold rounded-lg transition-colors ${mode === 'manual' ? 'bg-white dark:bg-slate-700 shadow-sm text-slate-800 dark:text-slate-200' : 'text-slate-500'}`}
                    >
                        Manuell
                    </button>
                </div>

                {mode === 'gemini' ? (
                    <form onSubmit={handleGenerateAI} className="space-y-6">
                        <div>
                            <label className="block text-sm font-bold text-slate-700 dark:text-slate-300 mb-2">Thema der Vokabeln</label>
                            <input 
                                required
                                value={topic}
                                onChange={e => setTopic(e.target.value)}
                                placeholder="z.B. Im Restaurant, Emotionen, Farben..."
                                className="w-full bg-slate-50 dark:bg-slate-900 border border-slate-300 dark:border-slate-700 rounded-xl p-4 text-lg focus:ring-2 focus:ring-indigo-500 outline-none transition-all"
                            />
                            <p className="text-xs text-slate-500 mt-2">Die KI generiert automatisch 10 passende Vokabeln samt Lautschrift und Emojis.</p>
                        </div>

                        {error && (
                            <div className="bg-red-50 dark:bg-red-950/30 text-red-600 dark:text-red-400 p-4 rounded-xl flex items-start text-sm">
                                <AlertCircle className="w-5 h-5 mr-2 shrink-0" /> {error}
                            </div>
                        )}

                        <button 
                            type="submit" 
                            disabled={isGenerating || !topic}
                            className={`w-full font-bold py-4 rounded-xl flex items-center justify-center transition-all ${
                                isGenerating ? 'bg-indigo-400 text-white cursor-not-allowed' : 'bg-indigo-600 text-white hover:bg-indigo-700 shadow-lg shadow-indigo-200 dark:shadow-none'
                            }`}
                        >
                            {isGenerating ? (
                                <><Loader2 className="w-5 h-5 animate-spin mr-2" /> Generiere Magie...</>
                            ) : (
                                <><Sparkles className="w-5 h-5 mr-2" /> Deck generieren lassen</>
                            )}
                        </button>
                    </form>
                ) : (
                    <form onSubmit={handleCreateManual} className="space-y-6">
                        <div>
                            <label className="block text-sm font-bold text-slate-700 dark:text-slate-300 mb-2">Name des Decks</label>
                            <input 
                                required
                                value={deckName}
                                onChange={e => setDeckName(e.target.value)}
                                placeholder="z.B. Meine Lieblingswörter"
                                className="w-full bg-slate-50 dark:bg-slate-900 border border-slate-300 dark:border-slate-700 rounded-xl p-4 text-lg focus:ring-2 focus:ring-indigo-500 outline-none transition-all"
                            />
                        </div>
                        <button 
                            type="submit" 
                            disabled={!deckName}
                            className="w-full bg-slate-800 text-white dark:bg-slate-100 dark:text-slate-900 font-bold py-4 rounded-xl hover:bg-slate-900 dark:hover:bg-white transition-colors"
                        >
                            Leeres Deck erstellen
                        </button>
                    </form>
                )}
            </div>
        </div>
    );
}

// --- Settings View ---
function SettingsView({ profile, onUpdate, toggleTheme, onBack }) {
    return (
        <div className="flex flex-col h-full animate-in fade-in slide-in-from-right-4 duration-300">
            <header className="p-4 flex items-center border-b border-slate-100 dark:border-slate-800">
                <button onClick={onBack} className="p-2 -ml-2 text-slate-500 hover:text-slate-800 dark:hover:text-slate-200">
                    <ArrowLeft className="w-6 h-6" />
                </button>
                <h2 className="font-bold text-lg ml-2">Einstellungen</h2>
            </header>

            <div className="p-6 space-y-8">
                {/* Theme Toggle */}
                <div className="flex items-center justify-between bg-white dark:bg-slate-800 p-4 rounded-2xl border border-slate-200 dark:border-slate-700 shadow-sm">
                    <div className="flex items-center space-x-3">
                        <div className={`p-2 rounded-lg ${profile.theme === 'dark' ? 'bg-indigo-900/50 text-indigo-400' : 'bg-orange-100 text-orange-500'}`}>
                            {profile.theme === 'dark' ? <Moon className="w-5 h-5" /> : <Sun className="w-5 h-5" />}
                        </div>
                        <span className="font-bold">Erscheinungsbild</span>
                    </div>
                    <button 
                        onClick={toggleTheme}
                        className="w-14 h-8 bg-slate-200 dark:bg-slate-700 rounded-full relative transition-colors duration-300"
                    >
                        <div className={`w-6 h-6 bg-white rounded-full absolute top-1 transition-all duration-300 shadow-sm ${profile.theme === 'dark' ? 'left-7 bg-indigo-500' : 'left-1'}`} />
                    </button>
                </div>

                {/* Daily Goal */}
                <div className="bg-white dark:bg-slate-800 p-5 rounded-2xl border border-slate-200 dark:border-slate-700 shadow-sm space-y-4">
                    <h3 className="font-bold text-slate-800 dark:text-slate-100">Tagesziel anpassen</h3>
                    <p className="text-sm text-slate-500">Wie viele Karten möchtest du jeden Tag wiederholen?</p>
                    
                    <div className="flex items-center space-x-4">
                        <input 
                            type="range" 
                            min="5" 
                            max="100" 
                            step="5"
                            value={profile.dailyGoal}
                            onChange={(e) => onUpdate({ dailyGoal: parseInt(e.target.value) })}
                            className="flex-1 accent-indigo-500"
                        />
                        <span className="font-bold text-xl text-indigo-600 dark:text-indigo-400 w-12 text-center">
                            {profile.dailyGoal}
                        </span>
                    </div>
                </div>

                <div className="text-center text-sm text-slate-400 pt-8">
                    KartveLearn v1.0.0
                </div>
            </div>
        </div>
    );
}
